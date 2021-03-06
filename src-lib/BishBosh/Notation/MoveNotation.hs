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

 [@DESCRIPTION@]	Implements various move-notations <https://en.wikipedia.org/wiki/Chess_notation Chess-notation>.
-}

module BishBosh.Notation.MoveNotation(
-- * Type-classes
	ShowNotation(..),
	ShowNotationFloat(..),
-- * Types
-- ** Data-types
	MoveNotation(),
-- * Constants
	tag,
	coordinate,
	range,
-- * Functions
	readsQualifiedMove,
	showNotation,
	showsMoveSyntax,
	getOrigin,
	showsNotationFloatToNDecimals,
-- ** Predicates
	isCoordinate
) where

import			Control.Arrow((&&&))
import qualified	BishBosh.Attribute.Rank			as Attribute.Rank
import qualified	BishBosh.Cartesian.Coordinates		as Cartesian.Coordinates
import qualified	BishBosh.Component.EitherQualifiedMove	as Component.EitherQualifiedMove
import qualified	BishBosh.Component.QualifiedMove	as Component.QualifiedMove
import qualified	BishBosh.Component.Turn			as Component.Turn
import qualified	BishBosh.Notation.Coordinate		as Notation.Coordinate
import qualified	BishBosh.Notation.ICCFNumeric		as Notation.ICCFNumeric
import qualified	BishBosh.Notation.Smith			as Notation.Smith
import qualified	BishBosh.Property.ShowFloat		as Property.ShowFloat
import qualified	Control.Arrow
import qualified	Control.DeepSeq
import qualified	Data.Default
import qualified	Numeric
import qualified	Text.XML.HXT.Arrow.Pickle		as HXT
import qualified	Text.XML.HXT.Arrow.Pickle.Schema

-- | Used to qualify XML.
tag :: String
tag	= "moveNotation"

{- |
	* Identifies the move-notations which can be used.

	* /Standard Algebraic/ isn't included here because conversion to or from a /QualifiedMove/ requires access to the /game/.
-}
data MoveNotation
	= Coordinate	-- ^ As used for communication with /xboard/.
	| ICCFNumeric	-- ^ <https://en.wikipedia.org/wiki/ICCF_numeric_notation>.
	| Smith		-- ^ <https://www.chessclub.com/user/chessviewer/smith.html>.
	deriving (Eq, Read, Show)

instance Control.DeepSeq.NFData MoveNotation where
	rnf _	= ()

instance Data.Default.Default MoveNotation where
	def	= Smith

instance HXT.XmlPickler MoveNotation where
	xpickle	= HXT.xpDefault Data.Default.def . HXT.xpWrap (read, show) . HXT.xpAttr tag . HXT.xpTextDT . Text.XML.HXT.Arrow.Pickle.Schema.scEnum $ map show range	-- CAVEAT: whether it'll be used as an XML-attribute or an XML-element isn't currently known.

-- | Constant.
coordinate :: MoveNotation
coordinate	= Coordinate

-- | The constant complete range of values.
range :: [MoveNotation]
range	= [Coordinate, ICCFNumeric, Smith]

-- | Reads a /move/ & /move-type/ from the specified 'MoveNotation'.
readsQualifiedMove :: (
	Enum	x,
	Enum	y,
	Ord	x,
	Ord	y
 )
	=> MoveNotation
	-> ReadS (Component.EitherQualifiedMove.EitherQualifiedMove x y)
readsQualifiedMove Coordinate	= map (Control.Arrow.first $ uncurry Component.EitherQualifiedMove.mkPartiallyQualifiedMove . (Notation.Coordinate.getMove &&& Attribute.Rank.getMaybePromotionRank)) . reads
readsQualifiedMove ICCFNumeric	= map (Control.Arrow.first $ uncurry Component.EitherQualifiedMove.mkPartiallyQualifiedMove . (Notation.ICCFNumeric.getMove &&& Attribute.Rank.getMaybePromotionRank)) . reads
readsQualifiedMove Smith	= map (Control.Arrow.first $ uncurry Component.EitherQualifiedMove.mkFullyQualifiedMove . (Component.QualifiedMove.getMove &&& Component.QualifiedMove.getMoveType) . Notation.Smith.getQualifiedMove) . reads

-- | Show the syntax required by a specific 'MoveNotation'.
showsMoveSyntax :: MoveNotation -> ShowS
showsMoveSyntax moveNotation	= showChar '/' . showString (
	case moveNotation of
		Coordinate	-> Notation.Coordinate.regexSyntax
		ICCFNumeric	-> Notation.ICCFNumeric.regexSyntax
		Smith		-> Notation.Smith.regexSyntax
 ) . showChar '/'

-- | Returns the origin of the specified coordinate-system.
getOrigin :: MoveNotation -> (Int, Int)
getOrigin Coordinate	= Notation.Coordinate.origin
getOrigin ICCFNumeric	= Notation.ICCFNumeric.origin
getOrigin Smith		= Notation.Smith.origin

-- | Predicate.
isCoordinate :: MoveNotation -> Bool
isCoordinate Coordinate	= True
isCoordinate _		= False

-- | An interface for types which can be rendered in a chess-notation.
class ShowNotation a where
	showsNotation	:: MoveNotation -> a -> ShowS

instance (Enum x, Enum y) => ShowNotation (Component.QualifiedMove.QualifiedMove x y) where
	showsNotation moveNotation qualifiedMove	= case moveNotation of
		Coordinate	-> shows $ Notation.Coordinate.mkCoordinate' move moveType
		ICCFNumeric	-> shows $ Notation.ICCFNumeric.mkICCFNumeric' move moveType
		Smith		-> shows $ Notation.Smith.fromQualifiedMove qualifiedMove
		where
			(move, moveType)	= Component.QualifiedMove.getMove &&& Component.QualifiedMove.getMoveType $ qualifiedMove

instance (Enum x, Enum y) => ShowNotation (Component.Turn.Turn x y) where
	showsNotation moveNotation	= showsNotation moveNotation . Component.Turn.getQualifiedMove

instance (Enum x, Enum y) => ShowNotation (Cartesian.Coordinates.Coordinates x y) where
	showsNotation Coordinate	= Notation.Coordinate.showsCoordinates
	showsNotation ICCFNumeric	= Notation.ICCFNumeric.showsCoordinates
	showsNotation Smith		= Notation.Smith.showsCoordinates

-- | Show an arbitrary datum using the specified notation.
showNotation :: (ShowNotation a) => MoveNotation -> a -> String
showNotation moveNotation	= ($ "") . showsNotation moveNotation

-- | An alternative to 'Property.ShowFloat.ShowFloat', which permits access to a specific move-notation.
class ShowNotationFloat a where
	showsNotationFloat	:: MoveNotation -> (Double -> ShowS) -> a -> ShowS

-- | Render the specified data in the specified notation, & to the specified number of decimal digits.
showsNotationFloatToNDecimals :: ShowNotationFloat a => MoveNotation -> Property.ShowFloat.NDecimalDigits -> a -> ShowS
showsNotationFloatToNDecimals moveNotation nDecimalDigits	= showsNotationFloat moveNotation (Numeric.showFFloat $ Just nDecimalDigits)

