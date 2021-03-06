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

	* Models the /board/ as a sparse array, each element of which might contain a /piece/.

	* N.B.: while this could be represented as @Data.Map.Map Coordinates Piece@, replacing 'Data.Array.IArray.!' with 'Data.Map.lookup',
	it actually required more space (despite having at most half the elements) & runs slower (because of 'compare').

	* cf. the piece-centric model of the board defined in "BishBosh.State.CoordinatesByRankByLogicalColour".
-}

module BishBosh.State.MaybePieceByCoordinates(
-- * Types
-- ** Type-synonyms
--	Transformation,
-- ** Data-types
	MaybePieceByCoordinates(),
-- * Constants
--	rankSeparator,
-- * Functions
	inferMoveType,
	findPieces,
	findBlockingPiece,
	findProximateKnights,
	findAttackerInDirection,
	sumPieceSquareValueByLogicalColour,
	listDestinationsFor,
--	listToRaster,
--	shows2D,
	show2D,
-- ** Accessors
	dereference,
--	getPieces,
-- ** Mutators
	defineCoordinates,
	movePiece,
-- ** Predicates
	isVacant,
	isOccupied,
	isClear,
	isObstructed,
	isEnPassantMove
) where

import			Control.Applicative((<|>))
import			Control.Arrow((&&&), (***))
import			Data.Array.IArray((!), (//))
import qualified	BishBosh.Attribute.ColourScheme			as Attribute.ColourScheme
import qualified	BishBosh.Attribute.Direction			as Attribute.Direction
import qualified	BishBosh.Attribute.LogicalColour		as Attribute.LogicalColour
import qualified	BishBosh.Attribute.LogicalColourOfSquare	as Attribute.LogicalColourOfSquare
import qualified	BishBosh.Attribute.MoveType			as Attribute.MoveType
import qualified	BishBosh.Attribute.PhysicalColour		as Attribute.PhysicalColour
import qualified	BishBosh.Attribute.Rank				as Attribute.Rank
import qualified	BishBosh.Cartesian.Abscissa			as Cartesian.Abscissa
import qualified	BishBosh.Cartesian.Coordinates			as Cartesian.Coordinates
import qualified	BishBosh.Cartesian.Ordinate			as Cartesian.Ordinate
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
import qualified	BishBosh.Text.ShowList				as Text.ShowList
import qualified	BishBosh.Types					as T
import qualified	Control.Arrow
import qualified	Control.DeepSeq
import qualified	Control.Exception
import qualified	Data.Array.IArray
import qualified	Data.Char
import qualified	Data.Default
import qualified	Data.List
import qualified	Data.List.Extra
import qualified	Data.Map
import qualified	Data.Maybe
import qualified	ToolShed.Data.List.Runlength

{- |
	* This structure allows one to determine what /piece/ (if any) is located at specific /coordinates/.

	* N.B.: this could be implemented using 'Data.Vector.Vector', which being indexed by 'Int' is no longer polymorphic & permits many unsafe operations; but the result is no faster.
-}
newtype MaybePieceByCoordinates x y	= MkMaybePieceByCoordinates {
	deconstruct	:: Data.Array.IArray.Array {-Boxed-} (
		Cartesian.Coordinates.Coordinates x y	-- The array-index has two dimensions.
	) (
		Maybe Component.Piece.Piece	-- Each square optionally contains a piece.
	)
} deriving (Eq, Ord)

-- | Used to separate the /ranks/ of the /board/ as represented by the IO-format <https://en.wikipedia.org/wiki/Forsyth%E2%80%93Edwards_Notation Forsyth-Edwards notation>.
rankSeparator :: Char
rankSeparator	= '/'

-- | Chops a list into a 2-D list.
listToRaster :: [a] -> [[a]]
listToRaster	= Data.List.Extra.chunksOf $ fromIntegral Cartesian.Abscissa.xLength {-CAVEAT: this also depends on the raster-order-}

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Read (MaybePieceByCoordinates x y) where
	readsPrec _	= Property.ForsythEdwards.readsFEN

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Show (MaybePieceByCoordinates x y) where
	showsPrec _	= Property.ForsythEdwards.showsFEN

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Property.ForsythEdwards.ReadsFEN (MaybePieceByCoordinates x y) where
	readsFEN s
		| length rows /= fromIntegral Cartesian.Ordinate.yLength || any (
			(/= fromIntegral Cartesian.Abscissa.xLength) . length
		) rows		= []	-- No parse.
		| otherwise	= [(MkMaybePieceByCoordinates . Cartesian.Coordinates.listArrayByCoordinates . concat $ reverse rows, remainder)]
		where
			(rows, remainder)	= Control.Arrow.first (
				map (
					concatMap (
						\c -> case reads [c] of
							[(i, "")]	-> replicate i Nothing	-- Expand the runlength-code so that each row has the same length.
							_		-> [Just piece | (piece, []) <- Property.ForsythEdwards.readsFEN [c]] -- List-comprehension.
					)
				) . Text.ShowList.splitOn (== rankSeparator)
			 ) . span (
				`elem` rankSeparator : concatMap Property.ForsythEdwards.showFEN Component.Piece.range ++ concatMap show [1 .. Cartesian.Abscissa.xLength]
			 ) $ Data.List.Extra.trimStart s

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Property.ForsythEdwards.ShowsFEN (MaybePieceByCoordinates x y) where
	showsFEN MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= foldr1 (
		flip (.)	-- Render the line with the highest y-coordinate first.
	 ) . Data.List.intersperse (
		showChar rankSeparator	-- Separate the lines.
	 ) . map (
		foldr1 (.) . concatMap (
			\(runLength, maybePiece) -> Data.Maybe.maybe [
				shows runLength	-- Represent empty squares.
			] (
				replicate runLength . Property.ForsythEdwards.showsFEN	-- Render each piece.
			) maybePiece
		) . ToolShed.Data.List.Runlength.encode
	 ) . listToRaster $ Data.Array.IArray.elems byCoordinates

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Data.Default.Default (MaybePieceByCoordinates x y) where
	def = Property.ForsythEdwards.readFEN . Data.List.intercalate [rankSeparator] $ map ($ Attribute.LogicalColour.Black) [
		showNobility,
		showPawnRow
	 ] ++ replicate 4 "8" ++ map ($ Attribute.LogicalColour.White) [
		showPawnRow,
		showNobility
	 ] where
		showPieces :: [Component.Piece.Piece] -> String
		showPieces	= concatMap Property.ForsythEdwards.showFEN

		showPawnRow, showNobility :: Attribute.LogicalColour.LogicalColour -> String
		showPawnRow logicalColour	= showPieces . replicate (fromIntegral Cartesian.Abscissa.xLength) $ Component.Piece.mkPawn logicalColour
		showNobility logicalColour	= showPieces $ map (Component.Piece.mkPiece logicalColour) Attribute.Rank.nobility

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Property.Reflectable.ReflectableOnX (MaybePieceByCoordinates x y) where
	reflectOnX MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= MkMaybePieceByCoordinates . Data.Array.IArray.array (minBound, maxBound) . map (
		Property.Reflectable.reflectOnX *** fmap Property.Opposable.getOpposite
	 ) $ Data.Array.IArray.assocs byCoordinates

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Property.Reflectable.ReflectableOnY (MaybePieceByCoordinates x y) where
	reflectOnY MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= MkMaybePieceByCoordinates . Data.Array.IArray.array (minBound, maxBound) . map (
		Control.Arrow.first Property.Reflectable.reflectOnY
	 ) $ Data.Array.IArray.assocs byCoordinates

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => Property.Empty.Empty (MaybePieceByCoordinates x y) where
	empty	= MkMaybePieceByCoordinates . Cartesian.Coordinates.listArrayByCoordinates $ repeat Nothing

instance (
	Control.DeepSeq.NFData	x,
	Control.DeepSeq.NFData	y
 ) => Control.DeepSeq.NFData (MaybePieceByCoordinates x y) where
	rnf MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= Control.DeepSeq.rnf byCoordinates

instance (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => State.Censor.Censor (MaybePieceByCoordinates x y) where
	countPiecesByLogicalColour	= Data.List.foldl' (
		\acc piece -> let
			acc'@(nBlack, nWhite)	= (
				if Component.Piece.isBlack piece
					then Control.Arrow.first
					else Control.Arrow.second
			 ) succ acc
		in nBlack `seq` nWhite `seq` acc'
	 ) (0, 0) . getPieces

	countPieces	= length . getPieces

	countPieceDifferenceByRank	= Data.Array.IArray.accumArray (+) 0 (minBound, maxBound) . map (
		Component.Piece.getRank &&& (
			\piece -> (
				if Component.Piece.isBlack piece
					then negate
					else id
			) 1
		)
	 ) . getPieces

	hasInsufficientMaterial maybePieceByCoordinates	= all (
		(`notElem` Attribute.Rank.individuallySufficientMaterial) . Component.Piece.getRank . snd {-piece-}
	 ) locatedPieces && case blackKnights ++ whiteKnights of
		[]	-> Cartesian.Coordinates.areSquaresIsochromatic bishops
		[_]	-> null bishops
		_	-> False
		where
			locatedPieces	= findPieces maybePieceByCoordinates

			[blackKnights, blackBishops, whiteKnights, whiteBishops]	= [
				[
					coordinates |
						(coordinates, piece)	<- locatedPieces,
						piece == Component.Piece.mkPiece logicalColour rank
				] |
					logicalColour	<- Attribute.LogicalColour.range,
					rank		<- [Attribute.Rank.Knight, Attribute.Rank.Bishop]
			 ] -- List-comprehension.

			bishops	= blackBishops ++ whiteBishops

	hasBothKings maybePieceByCoordinates	= case Data.List.partition Component.Piece.isBlack . filter Component.Piece.isKing $ getPieces maybePieceByCoordinates of
		([_], [_])	-> True
		_		-> False

instance (Enum x, Enum y, Ord x, Ord y) => Component.Zobrist.Hashable2D MaybePieceByCoordinates x y {-CAVEAT: FlexibleInstances, MultiParamTypeClasses-} where
	listRandoms2D MkMaybePieceByCoordinates { deconstruct = byCoordinates } zobrist	= [
		uncurry Component.Zobrist.dereferenceRandomByCoordinatesByRankByLogicalColour (Component.Piece.getLogicalColour &&& Component.Piece.getRank $ piece) coordinates zobrist |
			(coordinates, Just piece)	<- Data.Array.IArray.assocs byCoordinates
	 ] -- List-comprehension.

-- | Dereference the array.
dereference :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Cartesian.Coordinates.Coordinates x y
	-> MaybePieceByCoordinates x y
	-> Maybe Component.Piece.Piece
{-# INLINE dereference #-}
dereference coordinates MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= byCoordinates ! coordinates

-- | Infer the type of the specified /move/.
inferMoveType :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y,
	Show	x,
	Show	y
 )
	=> Component.Move.Move x y
	-> Maybe Attribute.Rank.Rank	-- ^ The /rank/ to which a @Pawn@ should be promoted; defaulting to @Queen@.
	-> MaybePieceByCoordinates x y
	-> Attribute.MoveType.MoveType
{-# SPECIALISE inferMoveType :: Component.Move.Move T.X T.Y -> Maybe Attribute.Rank.Rank -> MaybePieceByCoordinates T.X T.Y -> Attribute.MoveType.MoveType #-}
inferMoveType move maybePromotionRank maybePieceByCoordinates@MkMaybePieceByCoordinates { deconstruct = byCoordinates }
	| Just sourcePiece <- byCoordinates ! Component.Move.getSource move	= case [
		moveType |
			Component.Piece.isKing sourcePiece,
			(moveType, kingsMove, _)	<- Component.Move.castlingMovesByLogicalColour ! Component.Piece.getLogicalColour sourcePiece,
			move == kingsMove
	] {-list-comprehension-} of
		moveType : _	-> moveType
		_
			| isEnPassantMove move maybePieceByCoordinates	-> Attribute.MoveType.enPassant	-- N.B.: if this move is valid, then one's opponent must have just double advanced an adjacent Pawn.
			| otherwise					-> Attribute.MoveType.mkNormalMoveType (
				fmap Component.Piece.getRank $ byCoordinates ! destination	-- Record the rank of any piece which was taken; the logical colour is inferred to be the opposite of 'sourcePiece'.
			) $ if Component.Piece.isPawnPromotion destination sourcePiece
				then maybePromotionRank <|> Just Attribute.Rank.defaultPromotionRank
				else Nothing
	| otherwise	= Control.Exception.throw . Data.Exception.mkSearchFailure . showString "BishBosh.State.MaybePieceByCoordinates.inferMoveType:\tno piece exists at " . shows (Component.Move.getSource move) . showString "; " $ shows maybePieceByCoordinates "."
	where
		destination	= Component.Move.getDestination move

{- |
	* Lists the destination-/coordinates/ to which the referenced /piece/ can move, & the /rank/ of any /piece/ taken.

	* N.B.: one can reference either player's /piece/, regardless of whose turn it is to move.

	* CAVEAT: doesn't include either /Castling/ or /En-passant/, because this function doesn't know the history of the game.

	* CAVEAT: doesn't check whether any proposed /move/ exposes one's @King@, because this function doesn't assume the existence of a @King@.

	* CAVEAT: the opponent's @King@ may be one of the destinations returned, but only if it was actually their move next.

	* CAVEAT: doesn't typically check whether anything (let alone the specified /piece/) exists at the specified source-/coordinates/.
-}
listDestinationsFor :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Cartesian.Coordinates.Coordinates x y				-- ^ The source for which destinations are required.
	-> Component.Piece.Piece						-- ^ The /piece/ at the specified source.
	-> MaybePieceByCoordinates x y
	-> [(Cartesian.Coordinates.Coordinates x y, Maybe Attribute.Rank.Rank)]	-- ^ The destination & the rank of any piece taken.
{-# SPECIALISE listDestinationsFor :: Cartesian.Coordinates.Coordinates T.X T.Y -> Component.Piece.Piece -> MaybePieceByCoordinates T.X T.Y -> [(Cartesian.Coordinates.Coordinates T.X T.Y, Maybe Attribute.Rank.Rank)] #-}
listDestinationsFor source piece maybePieceByCoordinates@MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= Control.Exception.assert (
	Data.Maybe.maybe False (== piece) $ byCoordinates ! source
 ) $ if Component.Piece.getRank piece `elem` Attribute.Rank.fixedAttackRange
	then {-P,N,K-} let
		findDestinations predicate	= [
			(destination, fmap Component.Piece.getRank maybeDestinationPiece) |
				destination	<- Component.Piece.findAttackDestinations source piece,
				let maybeDestinationPiece	= byCoordinates ! destination,
				predicate maybeDestinationPiece
		 ] -- List-comprehension.
	in if Component.Piece.isPawn piece
		then findDestinations (
			Data.Maybe.maybe False {-unoccupied-} $ (/= logicalColour) . Component.Piece.getLogicalColour
		) ++ let
			advance	:: (Enum y, Ord y) => Cartesian.Coordinates.Coordinates x y -> Cartesian.Coordinates.Coordinates x y
			advance	= Cartesian.Coordinates.advance logicalColour

			advancedLocation	= advance source
		in if isVacant advancedLocation maybePieceByCoordinates
			then (advancedLocation, Nothing) : [
				(doubleAdvancedLocation, Nothing) |
					Cartesian.Coordinates.isPawnsFirstRank logicalColour source,
					let doubleAdvancedLocation	= advance advancedLocation,
					isVacant doubleAdvancedLocation maybePieceByCoordinates
			] -- List-comprehension.
			else []	-- The path immediately ahead is blocked.
		else {-N,K-} findDestinations . Data.Maybe.maybe True {-unoccupied-} $ (/= logicalColour) . Component.Piece.getLogicalColour
	else {-R,B,Q-} let
		takeUntil (destination : remainder)
			| Just blockingPiece <- byCoordinates ! destination	= [
				(
					destination,
					Just $ Component.Piece.getRank blockingPiece
				) | Component.Piece.getLogicalColour blockingPiece /= logicalColour
			] -- List-comprehension.
			| otherwise	= (destination, Nothing) : takeUntil remainder	-- Recurse.
		takeUntil _	= []
	in [
		pairs |
			direction	<- Component.Piece.attackDirectionsByPiece Data.Map.! piece,
			pairs		<- takeUntil $ Cartesian.Coordinates.extrapolate direction source
	] -- List-comprehension.
	where
		logicalColour	= Component.Piece.getLogicalColour piece

-- | Show the /board/ in two dimensions, with /x/ & /y/ indexes.
shows2D :: (
	Enum		x,
	Enum		y,
	Integral	column,
	Ord		x,
	Ord		y
 )
	=> column	-- ^ The column-magnification.
	-> Attribute.ColourScheme.ColourScheme
	-> (Int, Int)	-- ^ The origin from which axes are labelled.
	-> MaybePieceByCoordinates x y
	-> ShowS	-- ^ The output suitable for display on a terminal.
shows2D boardColumnMagnification colourScheme (xOrigin, yOrigin) MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= (
	foldr (
		\(y, pairs) showsRow -> showsRow . showString (
			Attribute.PhysicalColour.selectGraphicsRendition True $ Attribute.PhysicalColour.mkFgColourCode Attribute.PhysicalColour.green
		) . showChar y . foldr (
			\(coordinates, c) acc' -> showString (
				Attribute.PhysicalColour.selectGraphicsRendition False . Attribute.PhysicalColour.mkBgColourCode $ (
					if Attribute.LogicalColourOfSquare.isBlack $ Cartesian.Coordinates.getLogicalColourOfSquare coordinates
						then Attribute.ColourScheme.getDarkSquareColour
						else Attribute.ColourScheme.getLightSquareColour
				 ) colourScheme
			) . showString (
				Attribute.PhysicalColour.selectGraphicsRendition True . Attribute.PhysicalColour.mkFgColourCode $ (
					if Data.Char.isLower c {-Black-}
						then Attribute.ColourScheme.getDarkPieceColour
						else Attribute.ColourScheme.getLightPieceColour
				 ) colourScheme
			) . let
				showPadding	= showString (fromIntegral (pred boardColumnMagnification) `replicate` ' ')
			in showPadding . showChar c . showPadding . acc'
		) showsReset pairs . showChar '\n'
	) id . zip (
		take (fromIntegral Cartesian.Ordinate.yLength) . enumFrom $ Data.Char.chr yOrigin
	) . listToRaster . map (
		Control.Arrow.second . Data.Maybe.maybe ' ' $ head . show	-- Represent each piece as a single character.
	) $ Data.Array.IArray.assocs byCoordinates
 ) . showString (
	replicate (fromIntegral boardColumnMagnification) ' '	-- Shift the line of x-axis labels right.
 ) . showString (
	Attribute.PhysicalColour.selectGraphicsRendition True $ Attribute.PhysicalColour.mkFgColourCode Attribute.PhysicalColour.green
 ) . foldr (.) showsReset (
	Data.List.intersperse (
		showString $ replicate (2 * fromIntegral (pred boardColumnMagnification)) ' '	-- Separate each of the x-axis labels.
	) . map showChar . take (
		fromIntegral Cartesian.Abscissa.xLength
	) . enumFrom $ Data.Char.chr xOrigin
 ) where
	showsReset :: ShowS
	showsReset	= showString $ Attribute.PhysicalColour.selectGraphicsRendition False 0

-- | Show the board using a two-dimensional representation.
show2D :: (
	Enum		x,
	Enum		y,
	Integral	column,
	Ord		x,
	Ord		y
 )
	=> column	-- ^ The column-magnification.
	-> Attribute.ColourScheme.ColourScheme
	-> (Int, Int)	-- ^ The origin from which axes are labelled.
	-> MaybePieceByCoordinates x y
	-> String	-- ^ The output suitable for display on a terminal.
show2D boardColumnMagnification colourScheme (xOrigin, yOrigin) maybePieceByCoordinates	= shows2D boardColumnMagnification colourScheme (xOrigin, yOrigin) maybePieceByCoordinates ""

-- | Extract the pieces from the board, discarding their coordinates.
getPieces :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => MaybePieceByCoordinates x y -> [Component.Piece.Piece]
getPieces MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= Data.Maybe.catMaybes $ Data.Array.IArray.elems byCoordinates

-- | Find all pieces.
findPieces :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 ) => MaybePieceByCoordinates x y -> [Component.Piece.LocatedPiece x y]
findPieces MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= [
	(coordinates, piece) |
		(coordinates, Just piece)	<- Data.Array.IArray.assocs byCoordinates
 ] -- List-comprehension.

{- |
	* Find the first /piece/ of either /logical colour/, encountered along a straight line in the specified /direction/, from just after the specified /coordinates/.

	* CAVEAT: this is a performance-hotspot.
-}
findBlockingPiece :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Attribute.Direction.Direction		-- ^ The direction in which to search.
	-> Cartesian.Coordinates.Coordinates x y	-- ^ The starting point.
	-> MaybePieceByCoordinates x y
	-> Maybe (Component.Piece.LocatedPiece x y)
{-# SPECIALISE findBlockingPiece :: Attribute.Direction.Direction -> Cartesian.Coordinates.Coordinates T.X T.Y -> MaybePieceByCoordinates T.X T.Y -> Maybe (Component.Piece.LocatedPiece T.X T.Y) #-}
{- CAVEAT: too slow.
findBlockingPiece direction source MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= Data.Maybe.listToMaybe . Data.Maybe.mapMaybe (
	uncurry fmap . ((,) &&& (byCoordinates !))
 ) $ Cartesian.Coordinates.extrapolate direction source
findBlockingPiece direction source maybePieceByCoordinates	= fmap (
	id &&& Data.Maybe.fromJust . (deconstruct maybePieceByCoordinates !)
 ) . Data.List.find (`isOccupied` maybePieceByCoordinates) $ Cartesian.Coordinates.extrapolate direction source
findBlockingPiece direction source MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= slave $ Cartesian.Coordinates.extrapolate direction source where
	slave (coordinates : remainder)	= case byCoordinates ! coordinates of
		Nothing		-> slave remainder	-- Recurse.
		Just piece	-> Just (coordinates, piece)
	slave _				= Nothing
findBlockingPiece direction source MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= Data.Maybe.listToMaybe [
	(coordinates, piece) |
		coordinates	<- Cartesian.Coordinates.extrapolate direction source,
		piece		<- Data.Maybe.maybeToList $ byCoordinates ! coordinates
 ] -- List-comprehension.
-}
findBlockingPiece direction source MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= Data.Maybe.listToMaybe [
	(coordinates, piece) |
		(coordinates, Just piece)	<- map (id &&& (byCoordinates !)) $ Cartesian.Coordinates.extrapolate direction source
 ] -- List-comprehension.

{- |
	* Find any @Knight@s of the specified /logical colour/, in attack-range around the specified /coordinates/.

	* CAVEAT: nothing is said about whether any /piece/ at the specified /coordinates/ belongs to the opponent, as one might expect.

	* CAVEAT: less efficient than 'State.CoordinatesByRankByLogicalColour.findProximateKnights'.
-}
findProximateKnights :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Attribute.LogicalColour.LogicalColour	-- ^ The /logical colour/ of the @Knight@ for which to search.
	-> Cartesian.Coordinates.Coordinates x y	-- ^ The destination to which the @Knight@ is required to be capable of jumping.
	-> MaybePieceByCoordinates x y
	-> [Cartesian.Coordinates.Coordinates x y]
findProximateKnights logicalColour destination MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= filter (
	Data.Maybe.maybe False (== knight) . (byCoordinates !)
 ) $ Component.Piece.findAttackDestinations destination knight where
	knight	= Component.Piece.mkKnight logicalColour

{- |
	* Find the /coordinates/ of any attacker who can strike the specified /coordinates/, in a straight line along the specified /direction/ (as seen by the target).

	* N.B.: there no requirement for there to actually be a /piece/ to attack at the specified target.
-}
findAttackerInDirection :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Attribute.LogicalColour.LogicalColour				-- ^ The defender's /logical colour/.
	-> Attribute.Direction.Direction					-- ^ The /direction/ from the /coordinates/ of concern; the opposite /direction/ from which an attacker might strike.
	-> Cartesian.Coordinates.Coordinates x y				-- ^ The defender's square.
	-> MaybePieceByCoordinates x y
	-> Maybe (Cartesian.Coordinates.Coordinates x y, Attribute.Rank.Rank)	-- ^ Any opposing /piece/ which can attack the specified square from the specified /direction/.
{-# SPECIALISE findAttackerInDirection :: Attribute.LogicalColour.LogicalColour -> Attribute.Direction.Direction -> Cartesian.Coordinates.Coordinates T.X T.Y -> MaybePieceByCoordinates T.X T.Y -> Maybe (Cartesian.Coordinates.Coordinates T.X T.Y, Attribute.Rank.Rank) #-}
findAttackerInDirection destinationLogicalColour direction destination	= (=<<) (
	\(source, sourcePiece) -> if Component.Piece.getLogicalColour sourcePiece /= destinationLogicalColour && Component.Piece.canAttackAlong source destination sourcePiece
		then Just (source, Component.Piece.getRank sourcePiece)
		else Nothing
 ) . findBlockingPiece direction destination

-- | Whether the specified /coordinates/ are unoccupied.
isVacant :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Cartesian.Coordinates.Coordinates x y
	-> MaybePieceByCoordinates x y
	-> Bool
{-# INLINE isVacant #-}
isVacant coordinates MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= Data.Maybe.isNothing $ byCoordinates ! coordinates

-- | Whether the specified /coordinates/ are occupied.
isOccupied :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Cartesian.Coordinates.Coordinates x y
	-> MaybePieceByCoordinates x y
	-> Bool
{-# INLINE isOccupied #-}
isOccupied coordinates	= not . isVacant coordinates

{- |
	* Whether the open interval (source, destination) is unobstructed.

	* N.B.: the specified end-points are uninspected.
-}
isClear :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Cartesian.Coordinates.Coordinates x y	-- ^ Source.
	-> Cartesian.Coordinates.Coordinates x y	-- ^ Destination.
	-> MaybePieceByCoordinates x y
	-> Bool
{-# SPECIALISE isClear :: Cartesian.Coordinates.Coordinates T.X T.Y -> Cartesian.Coordinates.Coordinates T.X T.Y -> MaybePieceByCoordinates T.X T.Y -> Bool #-}
isClear source destination maybePieceByCoordinates	= Control.Exception.assert (source /= destination) . all (`isVacant` maybePieceByCoordinates) . init {-discard the destination-} $ Cartesian.Coordinates.interpolate source destination

-- | Whether there's a blockage between a /piece/ presumed to exist at the specified source, & a /piece/ presumed to exist @ the specified destination.
isObstructed :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Cartesian.Coordinates.Coordinates x y	-- ^ Source.
	-> Cartesian.Coordinates.Coordinates x y	-- ^ Destination.
	-> MaybePieceByCoordinates x y
	-> Bool
{-# SPECIALISE isObstructed :: Cartesian.Coordinates.Coordinates T.X T.Y -> Cartesian.Coordinates.Coordinates T.X T.Y -> MaybePieceByCoordinates T.X T.Y -> Bool #-}
isObstructed source destination	= not . isClear source destination

{- |
	* Whether the specified /move/ matches the rules for /en-passant/.

	* CAVEAT: assumes that the /move/ is valid;
	otherwise one would also need to confirm that the opponent's @Pawn@ had just double-advanced into the appropriate position.
-}
isEnPassantMove :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Component.Move.Move x y
	-> MaybePieceByCoordinates x y
	-> Bool
{-# SPECIALISE isEnPassantMove :: Component.Move.Move T.X T.Y -> MaybePieceByCoordinates T.X T.Y -> Bool #-}
isEnPassantMove move maybePieceByCoordinates@MkMaybePieceByCoordinates { deconstruct = byCoordinates }
	| Just piece	<- byCoordinates ! source
	, let logicalColour	= Component.Piece.getLogicalColour piece
	= Cartesian.Coordinates.isEnPassantRank logicalColour source && Component.Piece.isPawn piece && destination `elem` Component.Piece.findAttackDestinations source piece && isVacant destination maybePieceByCoordinates	-- The move is either En-passant or invalid.
	| otherwise	= False	-- No piece.
	where
		(source, destination)	= Component.Move.getSource &&& Component.Move.getDestination $ move

-- | Self-documentation.
type Transformation x y	= MaybePieceByCoordinates x y -> MaybePieceByCoordinates x y

-- | Define the specified /coordinates/, by either placing or removing a /piece/.
defineCoordinates :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Maybe Component.Piece.Piece			-- ^ The optional /piece/ to place (or remove if @Nothing@ is specified).
	-> Cartesian.Coordinates.Coordinates x y	-- ^ The /coordinates/ to define.
	-> Transformation x y
defineCoordinates maybePiece coordinates MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= Control.Exception.assert (
	Data.Maybe.isJust maybePiece || Data.Maybe.isJust (byCoordinates ! coordinates)
 ) . MkMaybePieceByCoordinates $ byCoordinates // [(coordinates, maybePiece)]

{- |
	* Adjust the array to reflect a move.

	* CAVEAT: regrettably this allocates an entire array.
-}
movePiece :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> Component.Move.Move x y
	-> Component.Piece.Piece				-- ^ The (possibly promoted) piece to place at the destination.
	-> Maybe (Cartesian.Coordinates.Coordinates x y)	-- ^ Destination of any En-passant @Pawn@.
	-> Transformation x y
{-# SPECIALISE movePiece :: Component.Move.Move T.X T.Y -> Component.Piece.Piece -> Maybe (Cartesian.Coordinates.Coordinates T.X T.Y) -> Transformation T.X T.Y #-}
movePiece move destinationPiece maybeEnPassantDestination MkMaybePieceByCoordinates { deconstruct = byCoordinates }	= MkMaybePieceByCoordinates $ byCoordinates // Data.Maybe.maybe id (
	(:) . flip (,) Nothing	-- Take the Pawn en-passant.
 ) maybeEnPassantDestination [
	(
		Component.Move.getSource move,
		Nothing	-- Remove the piece from the source.
	), (
		Component.Move.getDestination move,
		Just destinationPiece	-- Place the piece at the destination, removing any opposing incumbent as a side-effect.
	)
 ]

-- | Calculate the total value of the /coordinates/ occupied by the /piece/s of either side.
sumPieceSquareValueByLogicalColour :: (
	Enum	x,
	Enum	y,
	Num	pieceSquareValue,
	Ord	x,
	Ord	y
 )
	=> Component.PieceSquareArray.FindPieceSquareValue x y pieceSquareValue
	-> MaybePieceByCoordinates x y
	-> [pieceSquareValue]
{-# SPECIALISE sumPieceSquareValueByLogicalColour :: Component.PieceSquareArray.FindPieceSquareValue T.X T.Y T.PieceSquareValue -> MaybePieceByCoordinates T.X T.Y -> [T.PieceSquareValue] #-}
sumPieceSquareValueByLogicalColour findPieceSquareValue	= (
	\(b, w) -> [b, w]
 ) . Data.List.foldl' (
	\(b, w) (coordinates, piece) -> let
		logicalColour		= Component.Piece.getLogicalColour piece
		pieceSquareValue	= findPieceSquareValue logicalColour (Component.Piece.getRank piece) coordinates
	in if Attribute.LogicalColour.isBlack logicalColour
		then let b' = b + pieceSquareValue in b' `seq` (b', w)
		else let w' = w + pieceSquareValue in w' `seq` (b, w')
 ) (0, 0) . findPieces

