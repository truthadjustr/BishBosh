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

 [@DESCRIPTION@]	Implements 'Test.QuickCheck.Arbitrary' & defines /QuickCheck/-properties.
-}

module BishBosh.Test.QuickCheck.Model.GameTerminationReason(
-- * Constants
	results
) where

import			BishBosh.Test.QuickCheck.Attribute.LogicalColour()
import			BishBosh.Test.QuickCheck.Model.DrawReason()
import			Control.Arrow((&&&))
import qualified	BishBosh.Model.GameTerminationReason	as Model.GameTerminationReason
import qualified	BishBosh.Property.Opposable		as Property.Opposable
import qualified	Test.QuickCheck

instance Test.QuickCheck.Arbitrary Model.GameTerminationReason.GameTerminationReason where
	arbitrary	= Test.QuickCheck.oneof [
		fmap Model.GameTerminationReason.mkCheckMate Test.QuickCheck.arbitrary,
		fmap Model.GameTerminationReason.mkResignation Test.QuickCheck.arbitrary,
		fmap Model.GameTerminationReason.mkDraw Test.QuickCheck.arbitrary
	 ]

-- | The constant test-results for this data-type.
results :: IO [Test.QuickCheck.Result]
results	= sequence [
	let
		f :: Model.GameTerminationReason.GameTerminationReason -> Test.QuickCheck.Property
		f	= Test.QuickCheck.label "GameTerminationReason.prop_getOpposite" . uncurry (==) . (Property.Opposable.getOpposite . Property.Opposable.getOpposite &&& id)
	in Test.QuickCheck.quickCheckWithResult Test.QuickCheck.stdArgs { Test.QuickCheck.maxSuccess = 8 } f
 ]

