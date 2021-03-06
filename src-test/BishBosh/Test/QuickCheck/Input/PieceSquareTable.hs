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

 [@DESCRIPTION@]	Implements 'Test.QuickCheck.Arbitrary'.
-}

module BishBosh.Test.QuickCheck.Input.PieceSquareTable(
-- * Types
-- ** Type-synonyms
	PieceSquareTable
) where

import			BishBosh.Test.QuickCheck.Component.Piece()
import qualified	BishBosh.Attribute.Rank		as Attribute.Rank
import qualified	BishBosh.Cartesian.Coordinates	as Cartesian.Coordinates
import qualified	BishBosh.Input.PieceSquareTable	as Input.PieceSquareTable
import qualified	BishBosh.Types			as T
import qualified	Test.QuickCheck

-- | Defines a concrete type for testing.
type PieceSquareTable	= Input.PieceSquareTable.PieceSquareTable T.X T.Y T.PieceSquareValue

instance (
	Enum		x,
	Enum		y,
	Fractional	pieceSquareValue,
	Ord		pieceSquareValue,
	Ord		x,
	Ord		y,
	Show		pieceSquareValue
 ) => Test.QuickCheck.Arbitrary (Input.PieceSquareTable.PieceSquareTable x y pieceSquareValue) where
--	{-# SPECIALISE instance Test.QuickCheck.Arbitrary PieceSquareTable #-}
	arbitrary	= do
		reflectOnY	<- Test.QuickCheck.arbitrary

		Input.PieceSquareTable.mkPieceSquareTable reflectOnY <$> mapM (
			\rank -> (,) rank <$> fmap (
				map $ recip . fromInteger . succ . (`mod` 100)	-- Normalise to the half open unit-interval (0,1].
			) (
				Test.QuickCheck.vector (
					(
						if reflectOnY
							then (`div` 2)
							else id
					) Cartesian.Coordinates.nSquares
				)
			)
		 ) Attribute.Rank.range

