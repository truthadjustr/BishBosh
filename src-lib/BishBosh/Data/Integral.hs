{-# OPTIONS_GHC -fno-warn-orphans #-}
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
-}

module BishBosh.Data.Integral(
-- * Functions
	stringToUnsignedDecimal
) where

import qualified	Data.Char
import qualified	Data.Int
import qualified	Data.List
import qualified	Data.Word
import qualified	Text.XML.HXT.Arrow.Pickle	as HXT

instance HXT.XmlPickler Data.Int.Int8 where
	xpickle	= HXT.xpPrim

instance HXT.XmlPickler Data.Int.Int16 where
	xpickle	= HXT.xpPrim

instance HXT.XmlPickler Data.Int.Int32 where
	xpickle	= HXT.xpPrim

instance HXT.XmlPickler Data.Word.Word8 where
	xpickle	= HXT.xpPrim

instance HXT.XmlPickler Data.Word.Word16 where
	xpickle	= HXT.xpPrim

instance HXT.XmlPickler Data.Word.Word32 where
	xpickle	= HXT.xpPrim

instance HXT.XmlPickler Data.Word.Word where
	xpickle	= HXT.xpPrim

{- |
	* N.B. much faster than the instance of 'Read' for the integral type. TODO: compare with 'Numeric.readDec'.

	* N.B. ignores any leading zeroes.

	* CAVEAT: 'Data.Char.digitToInt' throws an exception if it receives a character which isn't a digit.

-}
stringToUnsignedDecimal :: Num i => String -> i
stringToUnsignedDecimal	= fromIntegral . Data.List.foldl' (\i -> (+ 10 * i) . Data.Char.digitToInt) 0

