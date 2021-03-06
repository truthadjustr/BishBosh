{-# LANGUAGE FlexibleInstances, MultiParamTypeClasses #-}
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

	* This data-type maintains the state of the board, but it doesn't know its history.
	In consequence it knows neither whether Castling has already been performed nor which @Pawn@s have been promoted, nor whose turn it is.

	* It allows unvalidated access to the board, to place, move, or remove /piece/s.
	In consequence;
		it enforces neither a conventional layout for the /piece/s nor even that there is exactly one @King@ per side;
		it permits one to move into check or to take a @King@.

	* For efficiency, two models of the board are maintained; square-centric ("State.MaybePieceByCoordinates") & piece-centric ("State.CoordinatesByRankByLogicalColour").
-}

module BishBosh.State.Board(
-- * Types
-- ** Type-synonyms
--	Transformation,
--	NDefendersByCoordinatesByLogicalColour,
	NBoards,
-- ** Data-types
	Board(
--		MkBoard,
		getMaybePieceByCoordinates,
		getCoordinatesByRankByLogicalColour,
		getNDefendersByCoordinatesByLogicalColour,
		getNPiecesDifferenceByRank,
		getNPawnsByFileByLogicalColour,
		getNPieces,
		getPassedPawnCoordinatesByLogicalColour
	),
-- * Functions
	countDefendersByCoordinatesByLogicalColour,
	summariseNDefendersByLogicalColour,
	findProximateKnights,
	sumPieceSquareValueByLogicalColour,
	findAttackersOf,
	findAttacksBy,
-- ** Constructors
--	fromMaybePieceByCoordinates,
-- ** Mutators
	movePiece,
	defineCoordinates,
	placePiece,
	removePiece,
-- ** Predicates
	isKingChecked,
	exposesKing
) where

import			Control.Arrow((&&&), (***))
import			Data.Array.IArray((!), (//))
import qualified	BishBosh.Attribute.Direction			as Attribute.Direction
import qualified	BishBosh.Attribute.LogicalColour		as Attribute.LogicalColour
import qualified	BishBosh.Attribute.MoveType			as Attribute.MoveType
import qualified	BishBosh.Attribute.Rank				as Attribute.Rank
import qualified	BishBosh.Cartesian.Coordinates			as Cartesian.Coordinates
import qualified	BishBosh.Cartesian.Vector			as Cartesian.Vector
import qualified	BishBosh.Component.Move				as Component.Move
import qualified	BishBosh.Component.Piece			as Component.Piece
import qualified	BishBosh.Component.PieceSquareArray		as Component.PieceSquareArray
import qualified	BishBosh.Component.Zobrist			as Component.Zobrist
import qualified	BishBosh.Data.Exception				as Data.Exception
import qualified	BishBosh.Property.Empty				as Property.Empty
import qualified	BishBosh.Property.ForsythEdwards		as Property.ForsythEdwards
import qualified	BishBosh.Property.Opposable			as Property.Opposable
import qualified	BishBosh.Property.Reflectable			as Property.Reflectable
import qualified	BishBosh.State.Censor				as State.Censor
import qualified	BishBosh.State.CoordinatesByRankByLogicalColour	as State.CoordinatesByRankByLogicalColour
import qualified	BishBosh.State.MaybePieceByCoordinates		as State.MaybePieceByCoordinates
import qualified	BishBosh.Types					as T
import qualified	Control.Arrow
import qualified	Control.DeepSeq
import qualified	Control.Exception
import qualified	Data.Array.IArray
import qualified	Data.Default
import qualified	Data.List
import qualified	Data.Map
import qualified	Data.Maybe
import qualified	ToolShed.Data.List

-- | The type of a function which transforms a /board/.
type Transformation x y	= Board x y -> Board x y

-- | The number of defenders for each /piece/, belonging to each side.
type NDefendersByCoordinatesByLogicalColour x y	= Attribute.LogicalColour.ByLogicalColour (Data.Map.Map (Cartesian.Coordinates.Coordinates x y) Component.Piece.NPieces)

-- | A number of boards.
type NBoards	= Int

{- |
	* The board is modelled as two alternative structures representing the same data, but indexed by either /coordinates/ or /piece/.

	* For efficiency some ancillary structures are also maintained.
-}
data Board x y	= MkBoard {
	getMaybePieceByCoordinates			:: State.MaybePieceByCoordinates.MaybePieceByCoordinates x y,				-- ^ Defines any /piece/ currently located at each /coordinate/.
	getCoordinatesByRankByLogicalColour		:: State.CoordinatesByRankByLogicalColour.CoordinatesByRankByLogicalColour x y,		-- ^ The /coordinates/ of each /piece/.
	getNDefendersByCoordinatesByLogicalColour	:: NDefendersByCoordinatesByLogicalColour x y,						-- ^ The number of defenders of each /piece/, indexed by /logical colour/ & then by /coordinates/.
	getNPiecesDifferenceByRank			:: State.Censor.NPiecesByRank,								-- ^ The difference in the number of /piece/s of each /rank/ held by either side. @White@ /piece/s are arbitrarily considered positive & @Black@ ones negative.
	getNPawnsByFileByLogicalColour			:: State.CoordinatesByRankByLogicalColour.NPiecesByFileByLogicalColour x,		-- ^ The number of @Pawn@s of each /logical colour/, for each /file/.
	getNPieces					:: Component.Piece.NPieces,								-- ^ The total number of pieces on the board, including @Pawn@s.
	getPassedPawnCoordinatesByLogicalColour		:: State.CoordinatesByRankByLogicalColour.CoordinatesByLogicalColour x y		-- ^ The /coordinates/ of any /passed/ @Pawn@s.
}

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Eq (Board x y) where
	MkBoard { getMaybePieceByCoordinates = maybePieceByCoordinates } == MkBoard { getMaybePieceByCoordinates = maybePieceByCoordinates' }	= maybePieceByCoordinates == maybePieceByCoordinates'	-- N.B.: the remaining fields are implied.

instance (
	Control.DeepSeq.NFData	x,
	Control.DeepSeq.NFData	y
 ) => Control.DeepSeq.NFData (Board x y) where
	rnf MkBoard {
		getMaybePieceByCoordinates			= maybePieceByCoordinates,
		getCoordinatesByRankByLogicalColour		= coordinatesByRankByLogicalColour,
		getNDefendersByCoordinatesByLogicalColour	= nDefendersByCoordinatesByLogicalColour,
--		getNPiecesDifferenceByRank			= nPiecesDifferenceByRank,	-- N.B.: already strict.
		getNPawnsByFileByLogicalColour			= nPawnsByFileByLogicalColour,
		getNPieces					= nPieces,
		getPassedPawnCoordinatesByLogicalColour		= passedPawnCoordinatesByLogicalColour
	} = Control.DeepSeq.rnf (
		maybePieceByCoordinates,
		coordinatesByRankByLogicalColour,
		nDefendersByCoordinatesByLogicalColour,
--		nPiecesDifferenceByRank,
		nPawnsByFileByLogicalColour,
		nPieces,
		passedPawnCoordinatesByLogicalColour
	 )

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Read (Board x y) where
	{-# SPECIALISE instance Read (Board T.X T.Y) #-}
	readsPrec _	= Property.ForsythEdwards.readsFEN

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Show (Board x y) where
	showsPrec _	= Property.ForsythEdwards.showsFEN

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Property.ForsythEdwards.ReadsFEN (Board x y) where
	{-# SPECIALISE instance Property.ForsythEdwards.ReadsFEN (Board T.X T.Y) #-}
	readsFEN	= map (Control.Arrow.first fromMaybePieceByCoordinates) . Property.ForsythEdwards.readsFEN

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Property.ForsythEdwards.ShowsFEN (Board x y) where
	showsFEN MkBoard { getMaybePieceByCoordinates = maybePieceByCoordinates }	= Property.ForsythEdwards.showsFEN maybePieceByCoordinates

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Data.Default.Default (Board x y) where
	{-# SPECIALISE instance Data.Default.Default (Board T.X T.Y) #-}
	def	= fromMaybePieceByCoordinates Data.Default.def {-MaybePieceByCoordinates-}

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Property.Reflectable.ReflectableOnX (Board x y) where
	{-# SPECIALISE instance Property.Reflectable.ReflectableOnX (Board T.X T.Y) #-}
	reflectOnX MkBoard { getMaybePieceByCoordinates = maybePieceByCoordinates }	= fromMaybePieceByCoordinates $ Property.Reflectable.reflectOnX maybePieceByCoordinates

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Property.Reflectable.ReflectableOnY (Board x y) where
	{-# SPECIALISE instance Property.Reflectable.ReflectableOnY (Board T.X T.Y) #-}
	reflectOnY MkBoard { getMaybePieceByCoordinates = maybePieceByCoordinates }	= fromMaybePieceByCoordinates $ Property.Reflectable.reflectOnY maybePieceByCoordinates

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Property.Empty.Empty (Board x y) where
	{-# SPECIALISE empty :: Board T.X T.Y #-}
	empty	= fromMaybePieceByCoordinates Property.Empty.empty {-MaybePieceByCoordinates-}

instance (Enum x, Enum y, Ord x, Ord y) => Component.Zobrist.Hashable2D Board x y {-CAVEAT: FlexibleInstances, MultiParamTypeClasses-} where
	listRandoms2D MkBoard { getCoordinatesByRankByLogicalColour = coordinatesByRankByLogicalColour }	= Component.Zobrist.listRandoms2D coordinatesByRankByLogicalColour

-- | Constructor.
fromMaybePieceByCoordinates :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => State.MaybePieceByCoordinates.MaybePieceByCoordinates x y -> Board x y
{-# SPECIALISE fromMaybePieceByCoordinates :: State.MaybePieceByCoordinates.MaybePieceByCoordinates T.X T.Y -> Board T.X T.Y #-}
fromMaybePieceByCoordinates maybePieceByCoordinates	= board where
	board@MkBoard { getCoordinatesByRankByLogicalColour = coordinatesByRankByLogicalColour }	= MkBoard {
		getMaybePieceByCoordinates			= maybePieceByCoordinates,
		getCoordinatesByRankByLogicalColour		= State.CoordinatesByRankByLogicalColour.fromMaybePieceByCoordinates maybePieceByCoordinates,				-- Infer.
		getNDefendersByCoordinatesByLogicalColour	= countDefendersByCoordinatesByLogicalColour board,									-- Infer.
		getNPiecesDifferenceByRank			= State.Censor.countPieceDifferenceByRank coordinatesByRankByLogicalColour,						-- Infer.
		getNPawnsByFileByLogicalColour			= State.CoordinatesByRankByLogicalColour.countPawnsByFileByLogicalColour coordinatesByRankByLogicalColour,		-- Infer.
		getNPieces					= State.Censor.countPieces coordinatesByRankByLogicalColour,								-- Infer.
		getPassedPawnCoordinatesByLogicalColour		= State.CoordinatesByRankByLogicalColour.findPassedPawnCoordinatesByLogicalColour coordinatesByRankByLogicalColour	-- Infer.
	}

{- |
	* Moves the referenced /piece/.

	* CAVEAT: no validation is performed.

	* CAVEAT: /castling/ must be implemented by making two calls.
-}
movePiece :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y,
	Show	x,
	Show	y
 )
	=> Component.Move.Move x y		-- ^ N.B.: illegal moves are acceptable.
	-> Maybe Attribute.MoveType.MoveType	-- ^ N.B.: this may not be available to the caller, for example during the illegal moves required for rollback.
	-> Transformation x y
{-# SPECIALISE movePiece :: Component.Move.Move T.X T.Y -> Maybe Attribute.MoveType.MoveType -> Transformation T.X T.Y #-}
movePiece move maybeMoveType board@MkBoard {
	getMaybePieceByCoordinates			= maybePieceByCoordinates,
	getCoordinatesByRankByLogicalColour		= coordinatesByRankByLogicalColour,
	getNDefendersByCoordinatesByLogicalColour	= nDefendersByCoordinatesByLogicalColour,
	getNPiecesDifferenceByRank			= nPiecesDifferenceByRank,
	getNPieces					= nPieces
}
	| Just sourcePiece <- State.MaybePieceByCoordinates.dereference source	maybePieceByCoordinates	= let
		logicalColour	= Component.Piece.getLogicalColour sourcePiece

		moveType :: Attribute.MoveType.MoveType
		moveType -- CAVEAT: one can't call 'State.MaybePieceByCoordinates.inferMoveType', since that performs some validation of the move, which isn't the role of this module.
			| Just explicitMoveType	<- maybeMoveType					= explicitMoveType
			| State.MaybePieceByCoordinates.isEnPassantMove move maybePieceByCoordinates	= Attribute.MoveType.enPassant	-- N.B.: if this move is valid, then one's opponent must have just double-advanced an adjacent Pawn.
			| otherwise									= Attribute.MoveType.mkNormalMoveType (
				Component.Piece.getRank `fmap` State.MaybePieceByCoordinates.dereference destination maybePieceByCoordinates
			) $ if Component.Piece.isPawnPromotion destination sourcePiece
				then Just Attribute.Rank.defaultPromotionRank
				else Nothing

-- Derive the required values from moveType.
		eitherPassingPawnsDestinationOrMaybeTakenRank
			| Attribute.MoveType.isEnPassant moveType	= Left $ Cartesian.Coordinates.retreat logicalColour destination
			| otherwise					= Right $ Attribute.MoveType.getMaybeExplicitlyTakenRank moveType

		maybePromotionRank :: Maybe Attribute.Rank.Rank
		maybePromotionRank	= Attribute.Rank.getMaybePromotionRank moveType

		destinationPiece :: Component.Piece.Piece
		destinationPiece	= Data.Maybe.maybe id Component.Piece.promote maybePromotionRank sourcePiece

		board'@MkBoard { getMaybePieceByCoordinates = maybePieceByCoordinates' }	= MkBoard {
			getMaybePieceByCoordinates	= State.MaybePieceByCoordinates.movePiece move destinationPiece (
				either Just (const Nothing) eitherPassingPawnsDestinationOrMaybeTakenRank
			) maybePieceByCoordinates,
			getCoordinatesByRankByLogicalColour	= State.CoordinatesByRankByLogicalColour.movePiece move sourcePiece maybePromotionRank eitherPassingPawnsDestinationOrMaybeTakenRank coordinatesByRankByLogicalColour,
			getNDefendersByCoordinatesByLogicalColour	= let
				oppositePiece					= Property.Opposable.getOpposite sourcePiece
				opponentsLogicalColour				= Component.Piece.getLogicalColour oppositePiece
				eitherPassingPawnsDestinationOrMaybeTakenPiece	= fmap (Component.Piece.mkPiece opponentsLogicalColour) `fmap` eitherPassingPawnsDestinationOrMaybeTakenRank

			in (
				\(nBlackDefendersByCoordinates, nWhiteDefendersByCoordinates)	-> Attribute.LogicalColour.listArrayByLogicalColour [nBlackDefendersByCoordinates, nWhiteDefendersByCoordinates]
			) . foldr (
				\(affectedCoordinates, affectedPiece) -> if Component.Piece.isKing affectedPiece
					then id	-- N.B.: defence of the King is irrelevant, since one can't get to a position where it can be taken.
					else let
						logicalColour'	= Component.Piece.getLogicalColour affectedPiece
					in (
						if Attribute.LogicalColour.isBlack logicalColour'
							then Control.Arrow.first
							else Control.Arrow.second
					) . Data.Map.insert affectedCoordinates {-overwrite-} . length $ findAttackersOf (
						Property.Opposable.getOpposite logicalColour'	-- Investigate an attack on the affected coordinates by the affected piece's own logical colour, i.e. defence.
					) affectedCoordinates board'
			) (
				(! Attribute.LogicalColour.Black) &&& (! Attribute.LogicalColour.White) $ nDefendersByCoordinatesByLogicalColour // (
					let
						nDefendersByCoordinates	= nDefendersByCoordinatesByLogicalColour ! opponentsLogicalColour
					in either (
						\passingPawnsDestination -> (:) (
							opponentsLogicalColour,
							Data.Map.delete passingPawnsDestination nDefendersByCoordinates	-- This Pawn has been taken.
						)
					) (
						\maybeExplicitlyTakenRank -> if Data.Maybe.isJust maybeExplicitlyTakenRank
							then (:) (
								opponentsLogicalColour,
								Data.Map.delete destination nDefendersByCoordinates	-- This piece has been taken.
							)
							else id
					) eitherPassingPawnsDestinationOrMaybeTakenRank
				 ) [
					(
						logicalColour,
						Data.Map.delete source $ nDefendersByCoordinatesByLogicalColour ! logicalColour	-- This piece has been moved.
					) -- Pair.
				 ] -- Singleton.
			) . Data.List.nubBy (
				ToolShed.Data.List.equalityBy fst {-coordinates-}
			) $ [
				(affectedCoordinates, affectedPiece) |
					(knightsCoordinates, knight)	<- (source, sourcePiece) : map ((,) destination) (destinationPiece : either (const []) Data.Maybe.maybeToList eitherPassingPawnsDestinationOrMaybeTakenPiece),
					Component.Piece.isKnight knight,
					Just affectedCoordinates	<- Cartesian.Vector.maybeTranslate knightsCoordinates `map` (Cartesian.Vector.attackVectorsForKnight :: [Cartesian.Vector.VectorInt]),
					affectedPiece			<- Data.Maybe.maybeToList $ State.MaybePieceByCoordinates.dereference affectedCoordinates maybePieceByCoordinates',
					Component.Piece.isFriend knight affectedPiece
			] {-list-comprehension-} ++ [
				(blockingCoordinates, blockingPiece) |
					passingPawnsDestination			<- either return {-to List-monad-} (const []) eitherPassingPawnsDestinationOrMaybeTakenRank,
					(direction, antiParallelDirection)	<- Attribute.Direction.opposites,
					(blockingCoordinates, blockingPiece)	<- case ($ direction) &&& ($ antiParallelDirection) $ ($ maybePieceByCoordinates') . (`State.MaybePieceByCoordinates.findBlockingPiece` passingPawnsDestination) of
						(Just cp, Just cp')	-> [
							cp |
								let isDefendedBy from	= uncurry (&&) . uncurry (&&&) (Component.Piece.canAttackAlong from *** Component.Piece.isFriend $ cp),
								isDefendedBy passingPawnsDestination oppositePiece || uncurry isDefendedBy cp'
						 ] {-list-comprehension-} ++ [
							cp' |
								let isDefendedBy from	= uncurry (&&) . uncurry (&&&) (Component.Piece.canAttackAlong from *** Component.Piece.isFriend $ cp'),
								isDefendedBy passingPawnsDestination oppositePiece || uncurry isDefendedBy cp
						 ] -- List-comprehension.
						(Just cp, _)		-> [
							cp |
								uncurry (&&) $ uncurry (&&&) (Component.Piece.canAttackAlong passingPawnsDestination *** Component.Piece.isFriend $ cp) oppositePiece
						 ] -- List-comprehension.
						(_, Just cp')		-> [
							cp' |
								uncurry (&&) $ uncurry (&&&) (Component.Piece.canAttackAlong passingPawnsDestination *** Component.Piece.isFriend $ cp') oppositePiece
						 ] -- List-comprehension.
						_			-> []
			] {-list-comprehension-} ++ (destination, destinationPiece) : [
				(blockingCoordinates, blockingPiece) |
					let maybeExplicitlyTakenPiece	= either (const Nothing) id eitherPassingPawnsDestinationOrMaybeTakenPiece,
					(direction, antiParallelDirection)	<- Attribute.Direction.opposites,
					(coordinates, piece)			<- [(source, sourcePiece), (destination, destinationPiece)],
					(blockingCoordinates, blockingPiece)	<- case ($ direction) &&& ($ antiParallelDirection) $ ($ maybePieceByCoordinates') . (`State.MaybePieceByCoordinates.findBlockingPiece` coordinates) of
						(Just cp, Just cp')	-> [
							cp |
								let isDefendedBy from	= uncurry (&&) . uncurry (&&&) (Component.Piece.canAttackAlong from *** Component.Piece.isFriend $ cp),
								isDefendedBy coordinates piece || coordinates == destination && Data.Maybe.maybe False (isDefendedBy destination) maybeExplicitlyTakenPiece || uncurry isDefendedBy cp'
						 ] {-list-comprehension-} ++ [
							cp' |
								let isDefendedBy from	= uncurry (&&) . uncurry (&&&) (Component.Piece.canAttackAlong from *** Component.Piece.isFriend $ cp'),
								isDefendedBy coordinates piece || coordinates == destination && Data.Maybe.maybe False (isDefendedBy destination) maybeExplicitlyTakenPiece || uncurry isDefendedBy cp
						 ] -- List-comprehension.
						(Just cp, _)		-> [
							cp |
								let isDefendedBy	= uncurry (&&) . uncurry (&&&) (Component.Piece.canAttackAlong coordinates *** Component.Piece.isFriend $ cp),
								isDefendedBy piece || coordinates == destination && Data.Maybe.maybe False isDefendedBy maybeExplicitlyTakenPiece
						 ] -- List-comprehension.
						(_, Just cp')		-> [
							cp' |
								let isDefendedBy	= uncurry (&&) . uncurry (&&&) (Component.Piece.canAttackAlong coordinates *** Component.Piece.isFriend $ cp'),
								isDefendedBy piece || coordinates == destination && Data.Maybe.maybe False isDefendedBy maybeExplicitlyTakenPiece
						 ] -- List-comprehension.
						_			-> []
			], -- List-comprehension. Define any pieces whose defence may be affected by the move.
			getNPiecesDifferenceByRank	= Data.Array.IArray.accum (
				if Attribute.LogicalColour.isBlack logicalColour
					then (-)	-- Since White pieces are arbitrarily counted as positive, negate the adjustment if the current player is Black.
					else (+)
			) nPiecesDifferenceByRank $ if Attribute.MoveType.isEnPassant moveType
				then [(Attribute.Rank.Pawn, 1)]	-- Increment relative number of Pawns.
				else Data.Maybe.maybe id (
					(:) . flip (,) 1	-- Increment.
				) (
					Attribute.MoveType.getMaybeExplicitlyTakenRank moveType
				) $ Data.Maybe.maybe [] (
					\promotionRank -> [
						(
							promotionRank,
							1	-- Increment.
						), (
							Attribute.Rank.Pawn,
							negate 1	-- Decrement relative number of Pawns.
						)
					]
				) maybePromotionRank,
			getNPawnsByFileByLogicalColour	= if Component.Piece.isPawn sourcePiece && (
				Cartesian.Coordinates.getX source /= Cartesian.Coordinates.getX destination {-includes En-passant-} || Attribute.MoveType.isPromotion moveType
			) || Data.Maybe.maybe False (== Attribute.Rank.Pawn) (Attribute.MoveType.getMaybeExplicitlyTakenRank moveType)
				then State.CoordinatesByRankByLogicalColour.countPawnsByFileByLogicalColour coordinatesByRankByLogicalColour'
				else getNPawnsByFileByLogicalColour board,
			getNPieces	= Attribute.MoveType.nPiecesMutator moveType nPieces,
			getPassedPawnCoordinatesByLogicalColour	= if Component.Piece.isPawn sourcePiece {-includes En-passant & promotion-} || Data.Maybe.maybe False (== Attribute.Rank.Pawn) (Attribute.MoveType.getMaybeExplicitlyTakenRank moveType)
				then State.CoordinatesByRankByLogicalColour.findPassedPawnCoordinatesByLogicalColour coordinatesByRankByLogicalColour'
				else getPassedPawnCoordinatesByLogicalColour board
		}

		coordinatesByRankByLogicalColour'	= getCoordinatesByRankByLogicalColour board'
	in board'
	| otherwise	= Control.Exception.throw . Data.Exception.mkSearchFailure . showString "BishBosh.State.Board.movePiece:\tno piece exists at " . shows source . showString "; " $ shows board "."
	where
		(source, destination)	= Component.Move.getSource &&& Component.Move.getDestination $ move	-- Deconstruct.

{- |
	* Define the specified /coordinates/, by either placing or removing a /piece/.

	* CAVEAT: this function should only be used to construct custom scenarios, since /piece/s don't normally spring into existence.

	* CAVEAT: doesn't validate the request, so @King@s can be placed /in check/ & @Pawn@s can be placed behind their starting rank or unpromoted on their last /rank/.

	* CAVEAT: simple but inefficient implementation, since this function isn't called during normal play.
-}
defineCoordinates :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Maybe Component.Piece.Piece			-- ^ The optional /piece/ to place (or remove if @Nothing@ is specified).
	-> Cartesian.Coordinates.Coordinates x y	-- ^ The /coordinates/ to define.
	-> Transformation x y
{-# SPECIALISE defineCoordinates :: Maybe Component.Piece.Piece -> Cartesian.Coordinates.Coordinates T.X T.Y -> Transformation T.X T.Y #-}
defineCoordinates maybePiece coordinates MkBoard { getMaybePieceByCoordinates = maybePieceByCoordinates }	= fromMaybePieceByCoordinates $ State.MaybePieceByCoordinates.defineCoordinates maybePiece coordinates maybePieceByCoordinates

-- | Place a /piece/ at the specified unoccupied /coordinates/.
placePiece :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Component.Piece.Piece
	-> Cartesian.Coordinates.Coordinates x y
	-> Transformation x y
{-# SPECIALISE placePiece :: Component.Piece.Piece -> Cartesian.Coordinates.Coordinates T.X T.Y -> Transformation T.X T.Y #-}
placePiece piece coordinates board	= Control.Exception.assert (
	State.MaybePieceByCoordinates.isVacant coordinates $ getMaybePieceByCoordinates board
 ) $ defineCoordinates (Just piece) coordinates board

-- | Remove a /piece/ from the /board/.
removePiece :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Cartesian.Coordinates.Coordinates x y -> Transformation x y
{-# SPECIALISE removePiece :: Cartesian.Coordinates.Coordinates T.X T.Y -> Transformation T.X T.Y #-}
removePiece coordinates board	= Control.Exception.assert (
	State.MaybePieceByCoordinates.isOccupied coordinates $ getMaybePieceByCoordinates board
 ) $ defineCoordinates Nothing coordinates board

-- | Forward request.
findProximateKnights :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Attribute.LogicalColour.LogicalColour	-- ^ The /logical colour/ of the @Knight@ for which to search.
	-> Cartesian.Coordinates.Coordinates x y	-- ^ The destination to which the @Knight@ is required to be capable of jumping.
	-> Board x y
	-> [Cartesian.Coordinates.Coordinates x y]
{-# INLINE findProximateKnights #-}
-- findProximateKnights logicalColour coordinates MkBoard { getMaybePieceByCoordinates = maybePieceByCoordinates }	= State.MaybePieceByCoordinates.findProximateKnights logicalColour coordinates maybePieceByCoordinates
findProximateKnights logicalColour coordinates MkBoard { getCoordinatesByRankByLogicalColour = coordinatesByRankByLogicalColour }	= State.CoordinatesByRankByLogicalColour.findProximateKnights logicalColour coordinates coordinatesByRankByLogicalColour

-- | Calculate the total value of the /coordinates/ occupied by the /piece/s of either side, at a stage in the game's life-span defined by the total number of pieces remaining.
sumPieceSquareValueByLogicalColour :: (
	Enum	x,
	Enum	y,
	Num	pieceSquareValue,
	Ord	x,
	Ord	y
 )
	=> Component.PieceSquareArray.PieceSquareArray x y pieceSquareValue
	-> Board x y
	-> Attribute.LogicalColour.ByLogicalColour pieceSquareValue
{-# SPECIALISE sumPieceSquareValueByLogicalColour :: Component.PieceSquareArray.PieceSquareArray T.X T.Y T.PieceSquareValue -> Board T.X T.Y -> Attribute.LogicalColour.ByLogicalColour T.PieceSquareValue #-}
sumPieceSquareValueByLogicalColour pieceSquareArray MkBoard {
--	getMaybePieceByCoordinates		= maybePieceByCoordinates,
	getCoordinatesByRankByLogicalColour	= coordinatesByRankByLogicalColour,
	getNPieces				= nPieces
-- } = State.MaybePieceByCoordinates.sumPieceSquareValueByLogicalColour nPieces pieceSquareArray maybePieceByCoordinates
} = Attribute.LogicalColour.listArrayByLogicalColour $ State.CoordinatesByRankByLogicalColour.sumPieceSquareValueByLogicalColour (
	\logicalColour rank coordinates -> Component.PieceSquareArray.findPieceSquareValue nPieces logicalColour rank coordinates pieceSquareArray
 ) coordinatesByRankByLogicalColour

{- |
	* Lists the source-/coordinates/ from which the referenced destination can be attacked.

	* N.B.: the algorithm is independent of whose turn it actually is.

	* CAVEAT: checks neither the /logical colour/ of the defender, nor that their /piece/ even exists.

	* CAVEAT: may return the /coordinates/ of a diagonally adjacent @Pawn@; which would be an illegal move if there's not actually any /piece/ at the referenced destination.

	* CAVEAT: can't detect an en-passant attack, since this depends both on whether the previous move was a double advance & that the defender is a @Pawn@.
-}
findAttackersOf :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Attribute.LogicalColour.LogicalColour				-- ^ The defender's /logical colour/.
	-> Cartesian.Coordinates.Coordinates x y				-- ^ The defender's location.
	-> Board x y
	-> [(Cartesian.Coordinates.Coordinates x y, Attribute.Rank.Rank)]	-- ^ The locations from which the specified square can be attacked by the opposite /logical colour/.
{-# SPECIALISE findAttackersOf :: Attribute.LogicalColour.LogicalColour -> Cartesian.Coordinates.Coordinates T.X T.Y -> Board T.X T.Y -> [(Cartesian.Coordinates.Coordinates T.X T.Y, Attribute.Rank.Rank)] #-}
findAttackersOf destinationLogicalColour destination board@MkBoard { getMaybePieceByCoordinates	= maybePieceByCoordinates }	= [
	(coordinates, Attribute.Rank.Knight) |
		coordinates	<- findProximateKnights (Property.Opposable.getOpposite destinationLogicalColour) destination board
 ] {-list-comprehension-} ++ Data.Maybe.mapMaybe (
	\directionFromDestination -> State.MaybePieceByCoordinates.findAttackerInDirection destinationLogicalColour directionFromDestination destination maybePieceByCoordinates
 ) Attribute.Direction.range

{- |
	* Lists the source-/coordinates/ from which the referenced destination can be attacked by the specified type of /piece/.

	* N.B.: similar to 'findAttackersOf', but can be more efficient since the attacking /piece/ is known.

	* CAVEAT: can't detect an en-passant attack, since this depends both on whether the previous move was a double advance & that the defender is a @Pawn@.
-}
findAttacksBy :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Component.Piece.Piece			-- ^ The type of attacker.
	-> Cartesian.Coordinates.Coordinates x y	-- ^ The defender's location.
	-> Board x y
	-> [Cartesian.Coordinates.Coordinates x y]	-- ^ The sources from which the specified attacker could strike.
{-# SPECIALISE findAttacksBy :: Component.Piece.Piece -> Cartesian.Coordinates.Coordinates T.X T.Y -> Board T.X T.Y -> [Cartesian.Coordinates.Coordinates T.X T.Y] #-}
findAttacksBy piece destination board
	| rank == Attribute.Rank.Knight	= findProximateKnights logicalColour destination board
	| otherwise			= filter (
		\source -> source /= destination && Component.Piece.canAttackAlong source destination piece && State.MaybePieceByCoordinates.isClear source destination (getMaybePieceByCoordinates board)
	) . State.CoordinatesByRankByLogicalColour.dereference logicalColour rank $ getCoordinatesByRankByLogicalColour board
	where
		(logicalColour, rank)	= Component.Piece.getLogicalColour &&& Component.Piece.getRank $ piece

{- |
	* Whether the @King@ of the specified /logical colour/ is currently /checked/.

	* N.B.: independent of whose turn it actually is.

	* CAVEAT: assumes there's exactly one @King@ of the specified /logical colour/.
-}
isKingChecked :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Attribute.LogicalColour.LogicalColour	-- ^ The /logical colour/ of the @King@ in question.
	-> Board x y
	-> Bool
{-# SPECIALISE isKingChecked :: Attribute.LogicalColour.LogicalColour -> Board T.X T.Y -> Bool #-}
isKingChecked logicalColour board@MkBoard { getCoordinatesByRankByLogicalColour = coordinatesByRankByLogicalColour }	= not . null $ findAttackersOf logicalColour (State.CoordinatesByRankByLogicalColour.getKingsCoordinates logicalColour coordinatesByRankByLogicalColour) board

{- |
	* Whether one's own @King@ has become exposed in the proposed /board/.

	* CAVEAT: assumes that one's @King@ wasn't already checked.

	* CAVEAT: this function is a performance-hotspot.
-}
exposesKing :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Attribute.LogicalColour.LogicalColour	-- ^ The /logical colour/ of the player proposing to move.
	-> Component.Move.Move x y			-- ^ The /move/.
	-> Board x y					-- ^ The original /board/, i.e. prior to the /move/.
	-> Bool
{-# SPECIALISE exposesKing :: Attribute.LogicalColour.LogicalColour -> Component.Move.Move T.X T.Y -> Board T.X T.Y -> Bool #-}
exposesKing logicalColour move board@MkBoard { getCoordinatesByRankByLogicalColour = coordinatesByRankByLogicalColour }
	| source == kingsCoordinates	= not . null $ findAttackersOf logicalColour (Component.Move.getDestination move) board	-- CAVEAT: expensive, since all directions from the King may have to be explored.
	| Just directionFromKing	<- Cartesian.Vector.toMaybeDirection (
		Cartesian.Vector.measureDistance kingsCoordinates source	:: Cartesian.Vector.VectorInt
	) -- Confirm that one's own King is on a straight line with the start of the move.
	, let maybePieceByCoordinates	= getMaybePieceByCoordinates board
	, State.MaybePieceByCoordinates.isClear kingsCoordinates source maybePieceByCoordinates	-- Confirm that the straight line from one's own King to the start of the move, is clear.
	, Data.Maybe.maybe True {-Knight's move-} (
		not . Attribute.Direction.areAligned directionFromKing	-- The blocking piece has revealed any attacker.
	) $ Cartesian.Vector.toMaybeDirection (
		Component.Move.measureDistance move	:: Cartesian.Vector.VectorInt
	)
	, Just (_, attackersRank)	<- State.MaybePieceByCoordinates.findAttackerInDirection logicalColour directionFromKing source maybePieceByCoordinates	-- Confirm the existence of an obscured attacker.
	= attackersRank `notElem` Attribute.Rank.plodders	-- Confirm sufficient range to bridge the vacated space.
	| otherwise	= False
	where
		source			= Component.Move.getSource move
		kingsCoordinates	= State.CoordinatesByRankByLogicalColour.getKingsCoordinates logicalColour coordinatesByRankByLogicalColour

-- | Count the number of defenders of each /piece/ on the /board/.
countDefendersByCoordinatesByLogicalColour :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Board x y -> NDefendersByCoordinatesByLogicalColour x y
{-# SPECIALISE countDefendersByCoordinatesByLogicalColour :: Board T.X T.Y -> NDefendersByCoordinatesByLogicalColour T.X T.Y #-}
countDefendersByCoordinatesByLogicalColour board@MkBoard { getCoordinatesByRankByLogicalColour = coordinatesByRankByLogicalColour }	= Attribute.LogicalColour.listArrayByLogicalColour [
	Data.Map.fromList [
		(
			coordinates,
			length $ findAttackersOf (
				Property.Opposable.getOpposite logicalColour	-- Investigate an attack on these coordinates by one's own logical colour.
			) coordinates board
		) |
			rank		<- Attribute.Rank.expendable,
			coordinates	<- State.CoordinatesByRankByLogicalColour.dereference logicalColour rank coordinatesByRankByLogicalColour
	] {-list-comprehension-} | logicalColour <- Attribute.LogicalColour.range
 ] -- List-comprehension.

-- | Collapses 'NDefendersByCoordinatesByLogicalColour' into the total number of defenders on either side.
summariseNDefendersByLogicalColour :: Board x y -> Attribute.LogicalColour.ByLogicalColour Component.Piece.NPieces
summariseNDefendersByLogicalColour MkBoard { getNDefendersByCoordinatesByLogicalColour = nDefendersByCoordinatesByLogicalColour }	= Data.Array.IArray.amap (
	Data.Map.foldl' (+) 0	-- CAVEAT: 'Data.Foldable.sum' is too slow.
 ) nDefendersByCoordinatesByLogicalColour

