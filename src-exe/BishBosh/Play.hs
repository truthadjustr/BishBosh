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

	* Constructs the Zobrist data-type.

	* Analyses standard-opening moves in order to statically sort the move-tree.

	* Reads any persistent game-state from file, to initialise the play-state, which constructs the quantified move tree.

	* Constructs position-hashes for each node in the tree.

	* Calls the selected user-interface.
-}

module BishBosh.Play(
-- * Functions
	play
 ) where

import			Control.Arrow((&&&))
import qualified	BishBosh.Component.Zobrist					as Component.Zobrist
import qualified	BishBosh.ContextualNotation.PositionHashQualifiedMoveTree	as ContextualNotation.PositionHashQualifiedMoveTree
import qualified	BishBosh.ContextualNotation.QualifiedMoveForest			as ContextualNotation.QualifiedMoveForest
import qualified	BishBosh.Input.EvaluationOptions				as Input.EvaluationOptions
import qualified	BishBosh.Input.IOOptions					as Input.IOOptions
import qualified	BishBosh.Input.Options						as Input.Options
import qualified	BishBosh.Input.SearchOptions					as Input.SearchOptions
import qualified	BishBosh.Input.UIOptions					as Input.UIOptions
import qualified	BishBosh.Model.GameTree						as Model.GameTree
import qualified	BishBosh.Notation.MoveNotation					as Notation.MoveNotation
import qualified	BishBosh.Property.Empty						as Property.Empty
import qualified	BishBosh.Property.Tree						as Property.Tree
import qualified	BishBosh.Search.SearchState					as Search.SearchState
import qualified	BishBosh.State.PlayState					as State.PlayState
import qualified	BishBosh.Text.Show						as Text.Show
import qualified	BishBosh.Types							as T
import qualified	BishBosh.UI.CECP						as UI.CECP
import qualified	BishBosh.UI.Raw							as UI.Raw
import qualified	Control.DeepSeq
import qualified	Control.Exception
import qualified	Data.Array.IArray
import qualified	Data.Bits
import qualified	Data.Default
import qualified	Data.Maybe
import qualified	System.FilePath
import qualified	System.IO
import qualified	System.Random
import			System.FilePath((</>))

-- | Plays the game according to the specified configuration.
play :: (
	Control.DeepSeq.NFData	column,
	Control.DeepSeq.NFData	criterionWeight,
	Control.DeepSeq.NFData	pieceSquareValue,
	Control.DeepSeq.NFData	rankValue,
	Control.DeepSeq.NFData	row,
	Control.DeepSeq.NFData	weightedMean,
	Control.DeepSeq.NFData	x,
	Control.DeepSeq.NFData	y,
	Data.Array.IArray.Ix	x,
	Data.Bits.FiniteBits	positionHash,
	Fractional		criterionValue,
	Fractional		pieceSquareValue,
	Fractional		rankValue,
	Fractional		weightedMean,
	Integral		column,
	Integral		x,
	Integral		y,
	Num			positionHash,
	Ord			positionHash,
	Read			x,
	Read			y,
	Real			criterionValue,
	Real			criterionWeight,
	Real			pieceSquareValue,
	Real			rankValue,
	Real			weightedMean,
	Show			column,
	Show			pieceSquareValue,
	Show			row,
	Show			x,
	Show			y,
	System.Random.Random	positionHash,
	System.Random.RandomGen	randomGen
 )
	=> randomGen
	-> Input.Options.Options column criterionWeight pieceSquareValue rankValue row x y
	-> ContextualNotation.QualifiedMoveForest.QualifiedMoveForest x y	-- ^ Standard openings.
	-> IO (State.PlayState.PlayState column criterionValue criterionWeight pieceSquareValue positionHash rankValue row weightedMean x y)
{-# SPECIALISE play :: (
	Control.DeepSeq.NFData	column,
	Control.DeepSeq.NFData	row,
	Integral		column,
	Show			column,
	Show			row,
	System.Random.RandomGen	randomGen
 )
	=> randomGen
	-> Input.Options.Options column T.CriterionWeight T.PieceSquareValue T.RankValue row T.X T.Y
	-> ContextualNotation.QualifiedMoveForest.QualifiedMoveForest T.X T.Y
	-> IO (State.PlayState.PlayState column T.CriterionValue T.CriterionWeight T.PieceSquareValue T.PositionHash T.RankValue row T.WeightedMean T.X T.Y)
 #-}
play randomGen options qualifiedMoveForest	= Data.Maybe.maybe (
	return {-to IO-monad-} Data.Default.def {-game-}
 ) (
	\(filePath, _) -> if any (System.FilePath.equalFilePath filePath) [
		showChar System.FilePath.pathSeparator "dev" </> "null", -- On *nix.
		"nul" -- On Windows ?
	]
		then return {-to IO-monad-} Data.Default.def {-game-}
		else Control.Exception.catch (
			do
				s	<- readFile filePath

				return {-to IO-monad-} $! read s	-- Force evaluation, to trigger any exception thrown from within 'catch'.
		) $ \e -> do
			System.IO.hPutStrLn System.IO.stderr . Text.Show.showsWarningPrefix . showString "'readFile' failed; " $ shows (e :: Control.Exception.SomeException) "."

			return {-to IO-monad-} Data.Default.def {-game-}
 ) (
	Input.IOOptions.getMaybePersistence ioOptions
 ) >>= (
	(
		\playState -> Data.Maybe.maybe (
			return {-to IO-monad-} playState
		) (
			\depth -> do
				System.IO.hPutStrLn System.IO.stderr . Text.Show.showsInfoPrefix . showString "Move-tree:\n" $ (
					uncurry Notation.MoveNotation.showsNotationFloatToNDecimals (
						Input.UIOptions.getMoveNotation &&& Input.UIOptions.getNDecimalDigits $ uiOptions
					) . Property.Tree.prune depth . Search.SearchState.getPositionHashQuantifiedGameTree $ State.PlayState.getSearchState playState
				 ) ""

				return {-to IO-monad-} playState
		) $ Input.UIOptions.getMaybePrintMoveTree uiOptions
	) . State.PlayState.initialise options zobrist (
		if Input.SearchOptions.getSortOnStandardOpeningMoveFrequency searchOptions
			then Model.GameTree.toMoveFrequency $ ContextualNotation.QualifiedMoveForest.toGameTree qualifiedMoveForest
			else Property.Empty.empty {-MoveFrequency-}
	)
 ) >>= (
	const UI.Raw.takeTurns `either` const UI.CECP.takeTurns $ Input.UIOptions.getEitherNativeUIOrCECPOptions uiOptions	-- Select a user-interface.
 ) (
	ContextualNotation.PositionHashQualifiedMoveTree.fromQualifiedMoveForest (
		Input.EvaluationOptions.getIncrementalEvaluation $ Input.Options.getEvaluationOptions options
	) zobrist qualifiedMoveForest
 ) randomGen where
	(ioOptions, searchOptions)	= Input.Options.getIOOptions &&& Input.Options.getSearchOptions $ options
	uiOptions			= Input.IOOptions.getUIOptions ioOptions

	zobrist	= Component.Zobrist.mkZobrist (Input.SearchOptions.getMaybeMinimumHammingDistance searchOptions) randomGen

