{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}
{-# OPTIONS_GHC -Wno-incomplete-record-updates #-}

-- | Implements the Head Protocol's /state machine/ as a /pure function/.
--
-- The protocol is described in two parts in the [Hydra paper](https://iohk.io/en/research/library/papers/hydrafast-isomorphic-state-channels/)
--
--     * One part detailing how the Head deals with /client input/.
--     * Another part describing how the Head reacts to /network messages/ from peers.
--     * A third part detailing the /On-Chain Verification (OCV)/ protocol, i.e. the abstract "smart contracts" that are need to provide on-chain security.
--
-- This module is about the first two parts, while the "Hydra.Contract.Head" module in 'hydra-plutus' covers the third part.
module Hydra.HeadLogic where

import Hydra.Prelude

import Data.List (elemIndex, (\\))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import GHC.Records (getField)
import Hydra.API.ClientInput (ClientInput (..))
import Hydra.API.ServerOutput (ServerOutput (..))
import Hydra.Chain (
  ChainEvent (..),
  ChainSlot,
  ChainStateType,
  HeadParameters (..),
  IsChainState (chainStateSlot),
  OnChainTx (..),
  PostChainTx (..),
  PostTxError,
 )
import Hydra.ContestationPeriod
import Hydra.Crypto (HydraKey, Signature, SigningKey, aggregateInOrder, sign, verify)
import Hydra.Ledger (
  IsTx,
  Ledger,
  UTxOType,
  ValidationError,
  ValidationResult (Invalid, Valid),
  applyTransactions,
  canApply,
 )
import Hydra.Network.Message (Message (..))
import Hydra.Party (Party (vkey))
import Hydra.Snapshot (ConfirmedSnapshot (..), Snapshot (..), SnapshotNumber (UnsafeSnapshotNumber), getSnapshot)

-- * Types

-- TODO: Move logic up and types down or re-organize using explicit exports

-- | The different events which are processed by the head logic (the "core").
-- Corresponding to each of the "shell" layers, we distinguish between events
-- from the client, the network and the chain.
data Event tx
  = -- | Event received from clients via the "Hydra.API".
    ClientEvent {clientInput :: ClientInput tx}
  | -- | Event received from peers via a "Hydra.Network".
    --
    --  * `ttl` is a simple counter that's decreased every time the event is
    --    reenqueued due to a wait. It's default value is `defaultTTL`
    NetworkEvent {ttl :: TTL, message :: Message tx}
  | -- | Event received from the chain via a "Hydra.Chain".
    OnChainEvent {chainEvent :: ChainEvent tx}
  | -- | Event to re-ingest errors from 'postTx' for further processing.
    PostTxError {postChainTx :: PostChainTx tx, postTxError :: PostTxError tx}
  deriving stock (Generic)

deriving instance (IsTx tx, IsChainState tx) => Eq (Event tx)
deriving instance (IsTx tx, IsChainState tx) => Show (Event tx)
deriving instance (IsTx tx, IsChainState tx) => ToJSON (Event tx)
deriving instance (IsTx tx, IsChainState tx) => FromJSON (Event tx)

instance
  ( IsTx tx
  , Arbitrary (ChainStateType tx)
  ) =>
  Arbitrary (Event tx)
  where
  arbitrary = genericArbitrary

-- | Analogous to events, the pure head logic "core" can have effects emited to
-- the "shell" layers and we distinguish the same: effects onto the client, the
-- network and the chain.
data Effect tx
  = -- | Effect to be handled by the "Hydra.API", results in sending this 'ServerOutput'.
    ClientEffect {serverOutput :: ServerOutput tx}
  | -- | Effect to be handled by a "Hydra.Network", results in a 'Hydra.Network.broadcast'.
    NetworkEffect {message :: Message tx}
  | -- | Effect to be handled by a "Hydra.Chain", results in a 'Hydra.Chain.postTx'.
    OnChainEffect {chainState :: ChainStateType tx, postChainTx :: PostChainTx tx}
  deriving stock (Generic)

deriving instance (IsTx tx, IsChainState tx) => Eq (Effect tx)
deriving instance (IsTx tx, IsChainState tx) => Show (Effect tx)
deriving instance (IsTx tx, IsChainState tx) => ToJSON (Effect tx)
deriving instance (IsTx tx, IsChainState tx) => FromJSON (Effect tx)

instance
  ( IsTx tx
  , Arbitrary (ChainStateType tx)
  ) =>
  Arbitrary (Effect tx)
  where
  arbitrary = genericArbitrary

-- | The main state of the Hydra protocol state machine. It holds both, the
-- overall protocol state, but also the off-chain 'CoordinatedHeadState'.
--
-- It is a recursive data structure, where 'previousRecoverableState' fields
-- record the state before the latest 'OnChainEvent' that has been observed.
-- On-Chain events are indeed only __eventually__ immutable and the application
-- state may be rolled back at any time (with a decreasing probability as the
-- time pass).
--
-- Thus, leverage functional immutable data-structure, we build a recursive
-- structure of states which we can easily navigate backwards when needed (see
-- 'Rollback' and 'rollback').
--
-- Note that currently, rolling back to a previous recoverable state eliminates
-- any off-chain events (e.g. transactions) that happened after that state. This
-- is particularly important for anything following the transition to
-- 'OpenState' since this is where clients may start submitting transactions. In
-- practice, clients should not send transactions right way but wait for a
-- certain grace period to minimize the risk.
data HeadState tx
  = IdleState {chainState :: ChainStateType tx}
  | InitialState
      { parameters :: HeadParameters
      , pendingCommits :: PendingCommits
      , committed :: Committed tx
      , previousRecoverableState :: HeadState tx
      , chainState :: ChainStateType tx
      }
  | OpenState
      { parameters :: HeadParameters
      , coordinatedHeadState :: CoordinatedHeadState tx
      , previousRecoverableState :: HeadState tx
      , chainState :: ChainStateType tx
      }
  | ClosedState
      { parameters :: HeadParameters
      , confirmedSnapshot :: ConfirmedSnapshot tx
      , previousRecoverableState :: HeadState tx
      , contestationDeadline :: UTCTime
      , -- | Tracks whether we have informed clients already about being
        -- 'ReadyToFanout'.
        readyToFanoutSent :: Bool
      , chainState :: ChainStateType tx
      }
  deriving stock (Generic)

instance (IsTx tx, Arbitrary (ChainStateType tx)) => Arbitrary (HeadState tx) where
  arbitrary = genericArbitrary

deriving instance (IsTx tx, Eq (ChainStateType tx)) => Eq (HeadState tx)
deriving instance (IsTx tx, Show (ChainStateType tx)) => Show (HeadState tx)
deriving instance (IsTx tx, ToJSON (ChainStateType tx)) => ToJSON (HeadState tx)
deriving instance (IsTx tx, FromJSON (ChainStateType tx)) => FromJSON (HeadState tx)

getChainState :: HeadState tx -> ChainStateType tx
getChainState hs = case hs of
  IdleState{chainState} -> chainState
  InitialState{chainState} -> chainState
  OpenState{chainState} -> chainState
  ClosedState{chainState} -> chainState

type Committed tx = Map Party (UTxOType tx)

-- | Off-chain state of the Coordinated Head protocol.
data CoordinatedHeadState tx = CoordinatedHeadState
  { -- | The latest UTxO of the "seen ledger".
    seenUTxO :: UTxOType tx
  , -- | List of seen transactions.
    seenTxs :: [tx]
  , -- | The latest confirmed snapshot, representing the "confirmed ledger".
    confirmedSnapshot :: ConfirmedSnapshot tx
  , -- | Whether we are currently collecting signatures for a snapshot.
    seenSnapshot :: SeenSnapshot tx
  }
  deriving stock (Generic)

instance IsTx tx => Arbitrary (CoordinatedHeadState tx) where
  arbitrary = genericArbitrary

deriving instance IsTx tx => Eq (CoordinatedHeadState tx)
deriving instance IsTx tx => Show (CoordinatedHeadState tx)
deriving instance IsTx tx => ToJSON (CoordinatedHeadState tx)
deriving instance IsTx tx => FromJSON (CoordinatedHeadState tx)

-- | Data structure to help in tracking whether we are currently collecting
-- signatures for a snapshot.
data SeenSnapshot tx
  = NoSeenSnapshot
  | RequestedSnapshot
  | SeenSnapshot
      { snapshot :: Snapshot tx
      , signatories :: Map Party (Signature (Snapshot tx))
      }
  deriving stock (Generic)

instance IsTx tx => Arbitrary (SeenSnapshot tx) where
  arbitrary = genericArbitrary

deriving instance IsTx tx => Eq (SeenSnapshot tx)
deriving instance IsTx tx => Show (SeenSnapshot tx)
deriving instance IsTx tx => ToJSON (SeenSnapshot tx)
deriving instance IsTx tx => FromJSON (SeenSnapshot tx)

type PendingCommits = Set Party

type TTL = Natural

defaultTTL :: TTL
defaultTTL = 5

-- | Preliminary type for collecting errors occurring during 'update'.
-- TODO: Try to merge this (back) into 'Outcome'.
data LogicError tx
  = InvalidEvent (Event tx) (HeadState tx)
  | InvalidState (HeadState tx)
  | InvalidSnapshot {expected :: SnapshotNumber, actual :: SnapshotNumber}
  | LedgerError ValidationError
  deriving stock (Generic)

instance (Typeable tx, Show (Event tx), Show (HeadState tx)) => Exception (LogicError tx)

instance (Arbitrary (Event tx), Arbitrary (HeadState tx)) => Arbitrary (LogicError tx) where
  arbitrary = genericArbitrary

deriving instance (Eq (HeadState tx), Eq (Event tx)) => Eq (LogicError tx)
deriving instance (Show (HeadState tx), Show (Event tx)) => Show (LogicError tx)
deriving instance (ToJSON (Event tx), ToJSON (HeadState tx)) => ToJSON (LogicError tx)
deriving instance (FromJSON (Event tx), FromJSON (HeadState tx)) => FromJSON (LogicError tx)

data Outcome tx
  = OnlyEffects {effects :: [Effect tx]}
  | NewState {headState :: HeadState tx, effects :: [Effect tx]}
  | Wait {reason :: WaitReason}
  | Error {error :: LogicError tx}
  deriving stock (Generic)

deriving instance (IsTx tx, IsChainState tx) => Eq (Outcome tx)
deriving instance (IsTx tx, IsChainState tx) => Show (Outcome tx)
deriving instance (IsTx tx, IsChainState tx) => ToJSON (Outcome tx)
deriving instance (IsTx tx, IsChainState tx) => FromJSON (Outcome tx)

instance (IsTx tx, Arbitrary (ChainStateType tx)) => Arbitrary (Outcome tx) where
  arbitrary = genericArbitrary

data WaitReason
  = WaitOnNotApplicableTx {validationError :: ValidationError}
  | WaitOnSnapshotNumber {waitingFor :: SnapshotNumber}
  | WaitOnSeenSnapshot
  | WaitOnContestationDeadline
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON, FromJSON)

instance Arbitrary WaitReason where
  arbitrary = genericArbitrary

data Environment = Environment
  { -- | This is the p_i from the paper
    party :: Party
  , -- NOTE(MB): In the long run we would not want to keep the signing key in
    -- memory, i.e. have an 'Effect' for signing or so.
    signingKey :: SigningKey HydraKey
  , otherParties :: [Party]
  , contestationPeriod :: ContestationPeriod
  }

-- * The Coordinated Head protocol

-- ** Opening the Head

-- | Client request to init the head. This leads to an init transaction on chain,
-- containing the head parameters.
--
-- TODO: maybe change signature so it takes [Party] instead (all parties)?
--
-- __Transition__: 'IdleState' → 'IdleState'
onIdleClientInit ::
  -- | Current chain state
  ChainStateType tx ->
  -- | Us
  Party ->
  -- | Others
  [Party] ->
  ContestationPeriod ->
  Outcome tx
onIdleClientInit chainState party otherParties contestationPeriod =
  OnlyEffects [OnChainEffect{chainState, postChainTx = InitTx parameters}]
 where
  parameters =
    HeadParameters
      { contestationPeriod
      , parties = party : otherParties
      }

-- | Observe an init transaction, initialize parameters in an 'InitialState' and
-- notify clients that they can now commit.
--
-- __Transition__: 'IdleState' → 'InitialState'
onIdleChainInitTx ::
  -- | Current head state.
  HeadState tx ->
  -- | New chain state.
  ChainStateType tx ->
  [Party] ->
  ContestationPeriod ->
  Outcome tx
onIdleChainInitTx headState newChainState parties contestationPeriod =
  NewState
    ( InitialState
        { parameters = HeadParameters{contestationPeriod, parties}
        , pendingCommits = Set.fromList parties
        , committed = mempty
        , previousRecoverableState = headState
        , chainState = newChainState
        }
    )
    [ClientEffect $ ReadyToCommit $ fromList parties]

-- | Client request to commit a UTxO entry to the head. Provided the client
-- hasn't committed yet, this leads to a commit transaction on-chain containing
-- that UTxO entry.
--
-- __Transition__: 'InitialState' → 'InitialState'
onInitialClientCommit ::
  -- | Current chain state
  ChainStateType tx ->
  Party ->
  PendingCommits ->
  ClientInput tx ->
  Outcome tx
onInitialClientCommit chainState party pendingCommits clientInput =
  case clientInput of
    (Commit utxo)
      -- REVIEW: Is 'canCommit' something we want to handle here or have the OCV
      -- deal with it?
      | canCommit -> OnlyEffects [OnChainEffect{chainState, postChainTx = CommitTx party utxo}]
    _ -> OnlyEffects [ClientEffect $ CommandFailed clientInput]
 where
  canCommit = party `Set.member` pendingCommits

-- | Observe a commit transaction and record the committed UTxO in the state.
-- Also, if this is the last commit to be observed, post a collect-com
-- transaction on-chain.
--
-- __Transition__: 'InitialState' → 'InitialState'
onInitialChainCommitTx ::
  Monoid (UTxOType tx) =>
  -- | Current head state; recorded as previous recoverable state
  HeadState tx ->
  -- | New chain state
  ChainStateType tx ->
  -- | Us
  Party ->
  HeadParameters ->
  PendingCommits ->
  Committed tx ->
  -- | Comitting party
  Party ->
  -- | Committed UTxO
  UTxOType tx ->
  Outcome tx
onInitialChainCommitTx headState newChainState party parameters pendingCommits committed pt utxo =
  NewState newHeadState $
    [ClientEffect $ Committed pt utxo]
      <> [ OnChainEffect
          { chainState = newChainState
          , postChainTx = CollectComTx collectedUTxO
          }
         | canCollectCom
         ]
 where
  newHeadState =
    InitialState
      { parameters
      , pendingCommits = remainingParties
      , committed = newCommitted
      , previousRecoverableState = headState
      , chainState = newChainState
      }
  remainingParties = Set.delete pt pendingCommits
  newCommitted = Map.insert pt utxo committed
  canCollectCom = null remainingParties && pt == party
  collectedUTxO = mconcat $ Map.elems newCommitted

-- | Client request to abort the head. This leads to an abort transaction on
-- chain, reimbursing already committed UTxOs.
--
-- __Transition__: 'InitialState' → 'InitialState'
onInitialClientAbort ::
  Monoid (UTxOType tx) =>
  -- | Current chain state
  ChainStateType tx ->
  Committed tx ->
  Outcome tx
onInitialClientAbort chainState committed =
  OnlyEffects [OnChainEffect{chainState, postChainTx = AbortTx (mconcat $ Map.elems committed)}]

-- | Observe an abort transaction by switching the state and notifying clients
-- about it.
--
-- __Transition__: 'InitialState' → 'IdleState'
onInitialChainAbortTx ::
  Monoid (UTxOType tx) =>
  -- | New chain state
  ChainStateType tx ->
  Committed tx ->
  Outcome tx
onInitialChainAbortTx newChainState committed =
  NewState
    IdleState{chainState = newChainState}
    [ClientEffect $ HeadIsAborted $ fold committed]

-- | Observe a collectCom transaction. We initialize the 'OpenState' using the
-- head parameters from 'IdleState' and construct an 'InitialSnapshot' holding
-- @u0@ from the committed UTxOs.
--
-- __Transition__: 'InitialState' → 'OpenState'
onInitialChainCollectTx ::
  (Foldable t, Monoid (UTxOType tx)) =>
  -- | Current head state; recorded as previous recoverable state
  HeadState tx ->
  -- | New chain state
  ChainStateType tx ->
  HeadParameters ->
  t (UTxOType tx) ->
  Outcome tx
onInitialChainCollectTx headState newChainState parameters committed =
  -- TODO: We would want to check whether this even matches our local state.
  -- For example, we do expect `null remainingParties` but what happens if
  -- it's untrue?
  let u0 = fold committed
      initialSnapshot = InitialSnapshot u0
   in NewState
        ( OpenState
            { parameters
            , coordinatedHeadState =
                CoordinatedHeadState u0 mempty initialSnapshot NoSeenSnapshot
            , previousRecoverableState = headState
            , chainState = newChainState
            }
        )
        [ClientEffect $ HeadIsOpen u0]

-- ** Off-chain protocol

-- | Client request to ingest a new transaction into the head. We do check
-- whether the given transaction can be applied against the confirmed ledger
-- state and yield a corresponding 'TxValid' or 'TxInvalid' client response.
--
-- __Transition__: 'OpenState' → 'OpenState'
onOpenClientNewTx ::
  Ledger tx ->
  -- | Us
  Party ->
  -- | UTxO from the last confirmed snapshot, a.k.a the confirmed ledger state.
  UTxOType tx ->
  -- | The transaction to be submitted to the head.
  tx ->
  Outcome tx
onOpenClientNewTx ledger party utxo tx =
  OnlyEffects effects
 where
  effects =
    case canApply ledger utxo tx of
      Valid ->
        [ ClientEffect $ TxValid tx
        , NetworkEffect $ ReqTx party tx
        ]
      Invalid err ->
        [ ClientEffect $ TxInvalid{utxo = utxo, transaction = tx, validationError = err}
        ]

-- | Receive network message about a new transaction request ('ReqTx') from a
-- peer. We apply this transaction to the seen utxo (ledger state), resulting in
-- an updated seen ledger state. If it is not applicable, then we wait to retry
-- later.
--
-- __Transition__: 'OpenState' → 'OpenState'
onOpenNetworkReqTx ::
  Ledger tx ->
  HeadParameters ->
  -- | Previous recoverable state (to re-create OpenState)
  HeadState tx ->
  -- | Current chain state (to re-create OpenState)
  ChainStateType tx ->
  -- | The offchain coordinated head state
  CoordinatedHeadState tx ->
  -- | The transaction to be submitted to the head.
  tx ->
  Outcome tx
onOpenNetworkReqTx ledger parameters previousRecoverableState chainState headState@CoordinatedHeadState{seenTxs, seenUTxO} tx =
  case applyTransactions ledger seenUTxO [tx] of
    Left (_, err) -> Wait $ WaitOnNotApplicableTx err -- The transaction may not be applicable yet.
    Right utxo' ->
      let newSeenTxs = seenTxs <> [tx]
       in NewState
            ( OpenState
                { parameters
                , coordinatedHeadState =
                    headState
                      { seenTxs = newSeenTxs
                      , -- FIXME: This is never reset otherwise. For example if
                        -- some other party was not up for some txs, but is up
                        -- again later and we would not agree with them on the
                        -- seen ledger.
                        seenUTxO = utxo'
                      }
                , previousRecoverableState
                , chainState
                }
            )
            [ClientEffect $ TxSeen tx]

-- | Receive network message about a snapshot request ('ReqSn') from a peer. We
-- do distinguish two cases:
--
--   * Case 1:
--
--       * The peer is the leader for requested snapshot number.
--       * Snapshot number is the next expected (based on the last confirmed)
--       * There is no snapshot pending, i.e. we are not collecting any signatures for a snapshot.
--
--       We try to apply the transactions of the requested snapshot to the confirmed utxo:
--
--           * If that succeeds, we do sign the snapshot, yield a snapshot
--             acknowledgment ('AckSn') and start tracking this snapshot.
--           * Else, we wait until the transactions become applicable.
--
--   * Case 2:
--
--       * The peer is the leader for requested snapshot number.
--       * Snapshot number is greater than the next expected.
--
--       We wait for the snapshots in between, i.e. until this 'ReqSn' is the next.
--
-- __Transition__: 'OpenState' → 'OpenState'
onOpenNetworkReqSn ::
  IsTx tx =>
  Ledger tx ->
  Party ->
  SigningKey HydraKey ->
  -- | Previous recoverable state (to re-create OpenState)
  HeadState tx ->
  -- | Current chain state (to re-create OpenState)
  ChainStateType tx ->
  HeadParameters ->
  -- | The offchain coordinated head state
  CoordinatedHeadState tx ->
  Party ->
  SnapshotNumber ->
  [tx] ->
  HeadState tx ->
  Event tx ->
  Outcome tx
onOpenNetworkReqSn
  ledger
  party
  signingKey
  previousRecoverableState
  chainState
  parameters
  s@CoordinatedHeadState{confirmedSnapshot, seenSnapshot}
  otherParty
  sn
  txs
  st
  ev
    | (number . getSnapshot) confirmedSnapshot + 1 == sn
        && isLeader parameters otherParty sn
        && not (snapshotPending seenSnapshot) =
      -- TODO: Also we might be robust against multiple ReqSn for otherwise
      -- valid request, which is currently leading to 'Error'
      -- TODO: Verify the request is signed by (?) / comes from the leader
      -- (Can we prove a message comes from a given peer, without signature?)
      case applyTransactions ledger (getField @"utxo" $ getSnapshot confirmedSnapshot) txs of
        Left (_, err) ->
          -- FIXME: this will not happen, as we are always comparing against the
          -- confirmed snapshot utxo?
          Wait $ WaitOnNotApplicableTx err
        Right u ->
          let nextSnapshot = Snapshot sn u txs
              snapshotSignature = sign signingKey nextSnapshot
           in NewState
                ( OpenState
                    { parameters
                    , coordinatedHeadState = s{seenSnapshot = SeenSnapshot nextSnapshot mempty}
                    , previousRecoverableState
                    , chainState
                    }
                )
                [NetworkEffect $ AckSn party snapshotSignature sn]
    | sn > (number . getSnapshot) confirmedSnapshot
        && isLeader parameters otherParty sn =
      -- TODO: How to handle ReqSN with sn > confirmed + 1
      -- This code feels contrived
      case seenSnapshot of
        SeenSnapshot{snapshot}
          | number snapshot == sn -> Error (InvalidEvent ev st)
          | otherwise -> Wait $ WaitOnSnapshotNumber (number snapshot)
        _ -> Wait WaitOnSeenSnapshot
    | otherwise = Error $ InvalidEvent ev st
   where
    snapshotPending :: SeenSnapshot tx -> Bool
    snapshotPending = \case
      SeenSnapshot{} -> True
      _ -> False

-- | Receive network message about a snapshot acknowledgement ('AckSn') from a
-- peer. We do distinguish two cases:
--
--   * Case 1: we received an AckSn request we did not expect
--
--       * respective AckSn and ReqSn out of order.
--       * multiple AckSns out of order.
--
--       In this case we simply wait to see the expected AckSn and we reenqueue the event.
--
--       The reason this can happen is because we don't make any assumptions on
--       the network packet delivery, and therefore the messages can arrive in
--       any order.
--
--   * Case 2: we received the expected Ack
--
--       * provided that the signature is valid, we add it to the set of signatories we have
--       * when we have gather all the signatures then we confirm the snapshot.
--       * when the signature is not valid then nothing changes.
--
-- __Transition__: 'OpenState' → 'OpenState'
onOpenNetworkAckSn ::
  IsTx tx =>
  [Party] ->
  Party ->
  HeadParameters ->
  -- | Previous recoverable state (to re-create OpenState)
  HeadState tx ->
  -- | Current chain state (to re-create OpenState)
  ChainStateType tx ->
  Signature (Snapshot tx) ->
  -- | The offchain coordinated head state
  CoordinatedHeadState tx ->
  SnapshotNumber ->
  Outcome tx
onOpenNetworkAckSn
  parties
  otherParty
  parameters
  previousRecoverableState
  chainState
  snapshotSignature
  headState@CoordinatedHeadState{seenSnapshot, seenTxs}
  sn =
    case seenSnapshot of
      NoSeenSnapshot -> Wait WaitOnSeenSnapshot
      RequestedSnapshot -> Wait WaitOnSeenSnapshot
      SeenSnapshot snapshot sigs
        | number snapshot /= sn -> Wait $ WaitOnSnapshotNumber (number snapshot)
        | otherwise ->
          let sigs'
                -- TODO: Must check whether we know the 'otherParty' signing the snapshot
                | verify (vkey otherParty) snapshotSignature snapshot = Map.insert otherParty snapshotSignature sigs
                | otherwise = sigs
              multisig = aggregateInOrder sigs' parties
              allMembersHaveSigned = Map.keysSet sigs' == Set.fromList parties
           in if allMembersHaveSigned
                then
                  NewState
                    ( OpenState
                        { parameters
                        , coordinatedHeadState =
                            headState
                              { confirmedSnapshot =
                                  ConfirmedSnapshot
                                    { snapshot
                                    , signatures = multisig
                                    }
                              , seenSnapshot = NoSeenSnapshot
                              , seenTxs = seenTxs \\ confirmed snapshot
                              }
                        , previousRecoverableState
                        , chainState
                        }
                    )
                    [ClientEffect $ SnapshotConfirmed snapshot multisig]
                else
                  NewState
                    ( OpenState
                        { parameters
                        , coordinatedHeadState =
                            headState
                              { seenSnapshot = SeenSnapshot snapshot sigs'
                              }
                        , previousRecoverableState
                        , chainState
                        }
                    )
                    []

-- ** Closing the Head

-- | Client request to close the head. This leads to a close transaction on
-- chain using the latest confirmed snaphshot of the 'OpenState'.
--
-- __Transition__: 'OpenState' → 'OpenState'
onOpenClientClose ::
  -- | Current chain state
  ChainStateType tx ->
  ConfirmedSnapshot tx ->
  Outcome tx
onOpenClientClose chainState confirmedSnapshot =
  OnlyEffects [OnChainEffect{chainState, postChainTx = CloseTx confirmedSnapshot}]

-- | Observe a close transaction. If the closed snapshot number is smaller than
-- our last confirmed, we post a contest transaction. Also, we do schedule a
-- notification for clients to fanout at the deadline.
--
-- __Transition__: 'OpenState' → 'ClosedState'
onOpenChainCloseTx ::
  HeadParameters ->
  -- | Current head state; recorded as previous recoverable state
  HeadState tx ->
  -- | New chain state
  ChainStateType tx ->
  -- | The offchain coordinated head state
  CoordinatedHeadState tx ->
  SnapshotNumber ->
  UTCTime ->
  Outcome tx
onOpenChainCloseTx
  parameters
  headState
  newChainState
  coordinatedHeadState
  closedSnapshotNumber
  contestationDeadline =
    -- TODO(2): In principle here, we want to:
    --
    --   a) Warn the user about a close tx outside of an open state
    --   b) Move to close state, using information from the close tx
    NewState closedState $
      ClientEffect headIsClosed :
        [ OnChainEffect
          { -- XXX: Field access on sum-type.
            chainState = getField @"chainState" headState
          , postChainTx = ContestTx{confirmedSnapshot}
          }
        | onChainEffectCondition
        ]
   where
    CoordinatedHeadState{confirmedSnapshot} =
      coordinatedHeadState
    closedState =
      ClosedState
        { parameters
        , confirmedSnapshot
        , contestationDeadline
        , readyToFanoutSent = False
        , previousRecoverableState = headState
        , chainState = newChainState
        }
    headIsClosed =
      HeadIsClosed
        { snapshotNumber = closedSnapshotNumber
        , contestationDeadline
        }
    onChainEffectCondition =
      number (getSnapshot confirmedSnapshot) > closedSnapshotNumber

-- | Observe a contest transaction. If the contested snapshot number is smaller
-- than our last confirmed snapshot, we post a contest transaction.
--
-- __Transition__: 'ClosedState' → 'ClosedState'
onClosedChainContestTx ::
  -- | Current chain state
  ChainStateType tx ->
  ConfirmedSnapshot tx ->
  SnapshotNumber ->
  Outcome tx
onClosedChainContestTx chainState confirmedSnapshot snapshotNumber
  | snapshotNumber < number (getSnapshot confirmedSnapshot) =
    OnlyEffects
      [ ClientEffect HeadIsContested{snapshotNumber}
      , OnChainEffect{chainState, postChainTx = ContestTx{confirmedSnapshot}}
      ]
  | snapshotNumber > number (getSnapshot confirmedSnapshot) =
    -- TODO: A more recent snapshot number was succesfully contested, we will
    -- not be able to fanout! We might want to communicate that to the client!
    OnlyEffects [ClientEffect HeadIsContested{snapshotNumber}]
  | otherwise =
    OnlyEffects [ClientEffect HeadIsContested{snapshotNumber}]

-- | Client request to fanout leads to a fanout transaction on chain using the
-- latest confirmed snapshot from 'ClosedState'.
--
-- __Transition__: 'ClosedState' → 'ClosedState'
onClosedClientFanout ::
  -- | Current chain state
  ChainStateType tx ->
  ConfirmedSnapshot tx ->
  UTCTime ->
  Outcome tx
onClosedClientFanout chainState confirmedSnapshot contestationDeadline =
  OnlyEffects
    [ OnChainEffect
        { chainState
        , postChainTx =
            FanoutTx
              { utxo = getField @"utxo" $ getSnapshot confirmedSnapshot
              , contestationDeadline
              }
        }
    ]

-- | Observe a fanout transaction by finalize the head state and notifying
-- clients about it.
--
-- __Transition__: 'ClosedState' → 'IdleState'
onClosedChainFanoutTx ::
  -- | New chain state
  ChainStateType tx ->
  ConfirmedSnapshot tx ->
  Outcome tx
onClosedChainFanoutTx newChainState confirmedSnapshot =
  NewState
    IdleState{chainState = newChainState}
    [ ClientEffect $ HeadIsFinalized $ getField @"utxo" $ getSnapshot confirmedSnapshot
    ]

-- | Observe a chain rollback and transition to corresponding previous
-- recoverable state.
--
-- __Transition__: 'OpenState' → 'HeadState'
onCurrentChainRollback ::
  (IsChainState tx) =>
  HeadState tx ->
  ChainSlot ->
  Outcome tx
onCurrentChainRollback currentState slot =
  NewState (rollback slot currentState) [ClientEffect RolledBack]
 where
  rollback rollbackSlot hs
    | chainStateSlot (getChainState hs) <= rollbackSlot = hs
    | otherwise =
      case hs of
        IdleState{} -> hs
        InitialState{previousRecoverableState} ->
          rollback rollbackSlot previousRecoverableState
        OpenState{previousRecoverableState} ->
          rollback rollbackSlot previousRecoverableState
        ClosedState{previousRecoverableState} ->
          rollback rollbackSlot previousRecoverableState

-- | The "pure core" of the Hydra node, which handles the 'Event' against a
-- current 'HeadState'. Resulting new 'HeadState's are retained and 'Effect'
-- outcomes handled by the "Hydra.Node".
update ::
  (IsTx tx, IsChainState tx) =>
  Environment ->
  Ledger tx ->
  HeadState tx ->
  Event tx ->
  Outcome tx
update Environment{party, signingKey, otherParties, contestationPeriod} ledger st ev = case (st, ev) of
  (IdleState{chainState}, ClientEvent Init) ->
    onIdleClientInit chainState party otherParties contestationPeriod
  (IdleState{}, OnChainEvent Observation{observedTx = OnInitTx{contestationPeriod = observed, parties}, newChainState}) ->
    onIdleChainInitTx st newChainState parties observed
  (InitialState{chainState, pendingCommits}, ClientEvent clientInput@(Commit _)) ->
    onInitialClientCommit chainState party pendingCommits clientInput
  ( InitialState{parameters, pendingCommits, committed}
    , OnChainEvent (Observation{observedTx = OnCommitTx{party = pt, committed = utxo}, newChainState})
    ) ->
      onInitialChainCommitTx st newChainState party parameters pendingCommits committed pt utxo
  (InitialState{committed}, ClientEvent GetUTxO) ->
    OnlyEffects [ClientEffect $ GetUTxOResponse (mconcat $ Map.elems committed)]
  (InitialState{chainState, committed}, ClientEvent Abort) ->
    onInitialClientAbort chainState committed
  (_, OnChainEvent (Observation{observedTx = OnCommitTx{}})) ->
    -- TODO: This should warn the user / client that something went _terribly_ wrong
    --       We shouldn't see any commit outside of the collecting (initial) state, if we do,
    --       there's an issue our logic or onChain layer.
    OnlyEffects []
  (InitialState{parameters, committed}, OnChainEvent (Observation{observedTx = OnCollectComTx{}, newChainState})) ->
    onInitialChainCollectTx st newChainState parameters committed
  (InitialState{committed}, OnChainEvent (Observation{observedTx = OnAbortTx{}, newChainState})) ->
    onInitialChainAbortTx newChainState committed
  (OpenState{chainState, coordinatedHeadState = CoordinatedHeadState{confirmedSnapshot}}, ClientEvent Close) ->
    onOpenClientClose chainState confirmedSnapshot
  (OpenState{coordinatedHeadState = CoordinatedHeadState{confirmedSnapshot}}, ClientEvent GetUTxO) ->
    OnlyEffects [ClientEffect . GetUTxOResponse $ getField @"utxo" $ getSnapshot confirmedSnapshot]
  ( OpenState{coordinatedHeadState = CoordinatedHeadState{confirmedSnapshot = getSnapshot -> Snapshot{utxo}}}
    , ClientEvent (NewTx tx)
    ) ->
      onOpenClientNewTx ledger party utxo tx
  (OpenState{parameters, coordinatedHeadState, previousRecoverableState, chainState}, NetworkEvent ttl (ReqTx _ tx))
    | ttl == 0 ->
      OnlyEffects [ClientEffect $ TxExpired tx]
    | otherwise ->
      -- XXX: This is decomposing 'OpenState', only to re-compose it inside this
      -- function. Create a dedicated OpenState type!
      onOpenNetworkReqTx ledger parameters previousRecoverableState chainState coordinatedHeadState tx
  ( OpenState
      { parameters
      , coordinatedHeadState = s@CoordinatedHeadState{}
      , previousRecoverableState
      , chainState
      }
    , evt@(NetworkEvent _ (ReqSn otherParty sn txs))
    ) ->
      -- XXX: This is decomposing 'OpenState', only to re-compose it inside this
      -- function. Create a dedicated OpenState type!
      onOpenNetworkReqSn ledger party signingKey previousRecoverableState chainState parameters s otherParty sn txs st evt
  ( OpenState
      { parameters = parameters@HeadParameters{parties}
      , coordinatedHeadState = headState@CoordinatedHeadState{}
      , previousRecoverableState
      , chainState
      }
    , NetworkEvent _ (AckSn otherParty snapshotSignature sn)
    ) ->
      -- XXX: This is decomposing 'OpenState', only to re-compose it inside this
      -- function. Create a dedicated OpenState type!
      onOpenNetworkAckSn parties otherParty parameters previousRecoverableState chainState snapshotSignature headState sn
  ( OpenState{parameters, coordinatedHeadState}
    , OnChainEvent (Observation{observedTx = OnCloseTx{snapshotNumber = closedSnapshotNumber, contestationDeadline}, newChainState})
    ) ->
      onOpenChainCloseTx parameters st newChainState coordinatedHeadState closedSnapshotNumber contestationDeadline
  (ClosedState{chainState, confirmedSnapshot}, OnChainEvent (Observation{observedTx = OnContestTx{snapshotNumber}})) ->
    onClosedChainContestTx chainState confirmedSnapshot snapshotNumber
  (cst@ClosedState{contestationDeadline, readyToFanoutSent}, OnChainEvent (Tick chainTime))
    | chainTime > contestationDeadline && not readyToFanoutSent ->
      NewState
        -- XXX: Requires -Wno-incomplete-record-updates. Should refactor
        -- 'HeadState' to hold individual 'ClosedState' etc. types
        (cst{readyToFanoutSent = True})
        [ClientEffect ReadyToFanout]
  (ClosedState{chainState, confirmedSnapshot, contestationDeadline}, ClientEvent Fanout) ->
    onClosedClientFanout chainState confirmedSnapshot contestationDeadline
  (ClosedState{confirmedSnapshot}, OnChainEvent (Observation{observedTx = OnFanoutTx{}, newChainState})) ->
    onClosedChainFanoutTx newChainState confirmedSnapshot
  (currentState, OnChainEvent (Rollback slot)) ->
    onCurrentChainRollback currentState slot
  (_, OnChainEvent Tick{}) ->
    OnlyEffects []
  (_, NetworkEvent _ (Connected nodeId)) ->
    OnlyEffects [ClientEffect $ PeerConnected nodeId]
  (_, NetworkEvent _ (Disconnected nodeId)) ->
    OnlyEffects [ClientEffect $ PeerDisconnected nodeId]
  (_, PostTxError{postChainTx, postTxError}) ->
    OnlyEffects [ClientEffect $ PostTxOnChainFailed{postChainTx, postTxError}]
  (_, ClientEvent{clientInput}) ->
    OnlyEffects [ClientEffect $ CommandFailed clientInput]
  _ ->
    Error $ InvalidEvent ev st

data SnapshotOutcome tx
  = ShouldSnapshot SnapshotNumber [tx] -- TODO(AB) : should really be a Set (TxId tx)
  | ShouldNotSnapshot NoSnapshotReason
  deriving (Eq, Show, Generic)

data NoSnapshotReason
  = NotLeader SnapshotNumber
  | SnapshotInFlight SnapshotNumber
  | NoTransactionsToSnapshot
  deriving (Eq, Show, Generic)

isLeader :: HeadParameters -> Party -> SnapshotNumber -> Bool
isLeader HeadParameters{parties} p (UnsafeSnapshotNumber sn) =
  case p `elemIndex` parties of
    Just i -> ((fromIntegral @Natural @Int sn - 1) `mod` length parties) == i
    _ -> False

-- | Snapshot emission decider
newSn :: IsTx tx => Environment -> HeadParameters -> CoordinatedHeadState tx -> SnapshotOutcome tx
newSn Environment{party} parameters CoordinatedHeadState{confirmedSnapshot, seenSnapshot, seenTxs} =
  let Snapshot{number} = getSnapshot confirmedSnapshot
      nextSnapshotNumber = succ number
   in if
          | not (isLeader parameters party nextSnapshotNumber) ->
            ShouldNotSnapshot $ NotLeader nextSnapshotNumber
          | seenSnapshot /= NoSeenSnapshot ->
            ShouldNotSnapshot $ SnapshotInFlight nextSnapshotNumber
          | null seenTxs ->
            ShouldNotSnapshot NoTransactionsToSnapshot
          | otherwise ->
            ShouldSnapshot nextSnapshotNumber seenTxs

-- TODO: This is the only logic NOT in 'update' and gets applied on top of it in
-- "Hydra.Node". We tried to do this decision inside 'update' in the past, but
-- ended up doing it here. Is it really not possible to just call this function
-- from the respective places in 'update'? i.e. as a last step on
-- 'onOpenNetworkReqTx' and 'onOpenNetworkAckSn'?
emitSnapshot :: IsTx tx => Environment -> [Effect tx] -> HeadState tx -> (HeadState tx, [Effect tx])
emitSnapshot env@Environment{party} effects = \case
  st@OpenState{parameters, coordinatedHeadState, previousRecoverableState, chainState} ->
    case newSn env parameters coordinatedHeadState of
      ShouldSnapshot sn txs ->
        ( OpenState
            { parameters
            , coordinatedHeadState = coordinatedHeadState{seenSnapshot = RequestedSnapshot}
            , previousRecoverableState
            , chainState
            }
        , NetworkEffect (ReqSn party sn txs) : effects
        )
      _ -> (st, effects)
  st -> (st, effects)
