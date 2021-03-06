{-
	Copyright (C) 2018 Dr. Alistair Ward

	This file is part of BishBosh.

	BishBosh is free software: you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation, either version 3 of the License, or
	(at your option) any later version.

	BishBosh is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License
	along with BishBosh.  If not, see <http://www.gnu.org/licenses/>.
-}
{- |
 [@AUTHOR@]	Dr. Alistair Ward

 [@DESCRIPTION@]

	* The instances of various moves, categorised by /logical colour/ & /rank/, are recorded from a large resource of games.

	* The frequency-distribution can then be used to sort the moves in the current game, to prioritise evaluation of likely candidates.
-}

module BishBosh.Model.MoveFrequency(
-- * Types
-- ** Type-synonyms
--	InstancesByMoveByRankByLogicalColour,
	GetRankAndMove,
-- ** Data-types
	MoveFrequency(),
-- * Functions
	countEntries,
--	countDistinctEntries,
	insertMoves,
	sortByDescendingMoveFrequency
) where

import			Data.Array.IArray((!), (//))
import qualified	BishBosh.Attribute.LogicalColour	as Attribute.LogicalColour
import qualified	BishBosh.Attribute.Rank			as Attribute.Rank
import qualified	BishBosh.Component.Move			as Component.Move
import qualified	BishBosh.Property.Empty			as Property.Empty
import qualified	BishBosh.Property.Null			as Property.Null
import qualified	Data.Foldable
import qualified	Data.List
import qualified	Data.List.Extra
import qualified	Data.Map
import qualified	Data.Ord

{- |
	* Records the number of instances, by /logical colour/, by /rank/, of /move/s.

	* CAVEAT: no record of the /move-type/ is stored.
-}
type InstancesByMoveByRankByLogicalColour move	= Attribute.LogicalColour.ByLogicalColour (Attribute.Rank.ByRank (Data.Map.Map move Component.Move.NMoves))

-- | The number of recorded instances of each move.
newtype MoveFrequency move	= MkMoveFrequency {
	deconstruct	:: InstancesByMoveByRankByLogicalColour move
} deriving Eq

instance Property.Empty.Empty (MoveFrequency move) where
	empty	= MkMoveFrequency . Attribute.LogicalColour.listArrayByLogicalColour . repeat . Attribute.Rank.listArrayByRank $ repeat Data.Map.empty

instance Property.Null.Null (MoveFrequency move) where
	isNull MkMoveFrequency { deconstruct = instancesByMoveByRankByLogicalColour }	= Data.Foldable.all (Data.Foldable.all Data.Map.null) instancesByMoveByRankByLogicalColour

-- | Count the total number of entries.
countEntries :: MoveFrequency move -> Component.Move.NMoves
countEntries MkMoveFrequency { deconstruct = instancesByMoveByRankByLogicalColour }	= Data.Foldable.foldl' (
	Data.Foldable.foldl' $ \acc -> (acc +) . Data.Foldable.sum
 ) 0 instancesByMoveByRankByLogicalColour

-- | Count the total number of distinct entries.
countDistinctEntries :: MoveFrequency move -> Component.Move.NMoves
countDistinctEntries MkMoveFrequency { deconstruct = instancesByMoveByRankByLogicalColour }	= Data.Foldable.foldl' (
	Data.Foldable.foldl' $ \acc -> (acc +) . Data.Map.size
 ) 0 instancesByMoveByRankByLogicalColour

-- | The type of a function which can extract the /rank/ & /move/ from a datum.
type GetRankAndMove a move	= a -> (Attribute.Rank.Rank, move)

{- |
	* Inserts a list of data from which /rank/ & /move/ can be extracted, each of which were made by pieces of the same /logical colour/, i.e. by the same player.

	* If the entry already exists, then the count for that /rank/ & /move/, is increased.
-}
insertMoves
	:: Ord move
	=> Attribute.LogicalColour.LogicalColour	-- ^ References the player who is required to make any one of the specified moves.
	-> GetRankAndMove a move			-- ^ How to extract the required /rank/ & /move/ from a datum.
	-> MoveFrequency move
	-> [a]						-- ^ The data from each of which, /rank/ & /move/ can be extracted.
	-> MoveFrequency move
insertMoves logicalColour getRankAndMove MkMoveFrequency { deconstruct = instancesByMoveByRankByLogicalColour } l	= MkMoveFrequency $ case l of
	[]	-> instancesByMoveByRankByLogicalColour
	[datum]	-> let
		(rank, move)	= getRankAndMove datum
		instancesByMove	= instancesByMoveByRank ! rank
	 in instancesByMoveByRankByLogicalColour // [
		(
			logicalColour,
			instancesByMoveByRank // [
				(
					rank,
					Data.Map.insertWith (+) move 1 instancesByMove
				) -- Pair.
			] -- Singleton.
		) -- Pair.
	 ] -- Singleton.
	_	-> instancesByMoveByRankByLogicalColour // [
		(
			logicalColour,
			instancesByMoveByRank // [
				(
					rank,
					foldr (
						\(_, move) -> Data.Map.insertWith (+) move 1
					) (
						instancesByMoveByRank ! rank
					) assocs
--				) | assocs@((rank, _) : _) <- Data.List.Extra.groupSortOn fst {-rank-} $ map getRankAndMove l	-- CAVEAT: wastes space.
				) | assocs@((rank, _) : _) <- Data.List.Extra.groupSortBy (Data.Ord.comparing fst {-rank-}) $ map getRankAndMove l
			] -- List-comprehension.
		) -- Pair.
	 ] -- Singleton.
	where
		instancesByMoveByRank	= instancesByMoveByRankByLogicalColour ! logicalColour

{- |
	* Sorts an arbitrary list on the recorded frequency of the /rank/ & /move/ accessible from each list-item.

	* The /rank/ & /move/ extracted from each list-item, is assumed to have been made by the player of the specified /logical colour/.
-}
sortByDescendingMoveFrequency
	:: Ord move
	=> Attribute.LogicalColour.LogicalColour	-- ^ References the player who is required to make any one of the specified moves.
	-> GetRankAndMove a move			-- ^ How to extract the required /rank/ & /move/ from a datum.
	-> MoveFrequency move
	-> [a]						-- ^ The data from each of which, /rank/ & /move/ can be extracted.
	-> [a]
{-# INLINE sortByDescendingMoveFrequency #-}
sortByDescendingMoveFrequency logicalColour getRankAndMove MkMoveFrequency { deconstruct = instancesByMoveByRankByLogicalColour }	= Data.List.sortOn $ negate {-most frequent first-} . (
	\(rank, move) -> Data.Map.findWithDefault 0 move $ instancesByMoveByRankByLogicalColour ! logicalColour ! rank
 ) . getRankAndMove

