{-# LANGUAGE CPP #-}
{-# LANGUAGE PatternSynonyms #-}

#if __GLASGOW_HASKELL__ == 808
-- Workaround for avoiding "mkPluginUsage: file not found" error.
-- https://gitlab.haskell.org/ghc/ghc/issues/16093
{-# OPTIONS_HADDOCK --optghc="-fobject-code" #-}
#endif

-- | This module defines a typechecker plugin that solves equations
-- involving units of measure.  To use it, add
--
-- > {-# OPTIONS_GHC -fplugin Data.UnitsOfMeasure.Plugin #-}
--
-- above the module header of your source files, or in the
-- @ghc-options@ field of your @.cabal@ file.  You do not need to
-- import this module.
module Data.UnitsOfMeasure.Plugin
  ( plugin
  ) where

import GhcApi
import GhcApi.Shim
    ( mkEqPred, mkFunnyEqEvidence
#if __GLASGOW_HASKELL__ < 802
    , pattern FunTy
#endif
    )
import GhcApi.Wrap (newGivenCt, newWantedCt)
import Data.Either
import Data.List

import Data.UnitsOfMeasure.Plugin.Convert
import Data.UnitsOfMeasure.Plugin.NormalForm
import Data.UnitsOfMeasure.Plugin.Unify


-- | The plugin that GHC will load when this module is used with the
-- @-fplugin@ option.
plugin :: Plugin
plugin = defaultPlugin { tcPlugin = const $ Just uomPlugin }

uomPlugin :: TcPlugin
uomPlugin = tracePlugin
                "uom-plugin"
                TcPlugin { tcPluginInit  = lookupUnitDefs
                         , tcPluginSolve = unitsOfMeasureSolver
                         , tcPluginStop  = const $ return ()
                         }


unitsOfMeasureSolver :: UnitDefs -> [Ct] -> [Ct] -> [Ct] -> TcPluginM TcPluginResult
unitsOfMeasureSolver uds givens _deriveds []      = do
    zonked_cts <- mapM zonkCt givens
    let (unit_givens , _) = partitionEithers $ zipWith foo givens $ map (toUnitEquality uds) zonked_cts
    case unit_givens of
      []    -> return $ TcPluginOk [] []
      (_:_) -> do
        sr <- simplifyUnits uds $ map snd unit_givens
        tcPluginTrace "unitsOfMeasureSolver simplified givens only" $ ppr sr
        case sr of
          -- Simplified tvs []    evs eqs -> TcPluginOk (map (solvedGiven . fst) unit_givens) []
          Simplified _    -> return $ TcPluginOk [] []
          Impossible eq _ -> reportContradiction uds eq
  where
    foo :: Ct -> Either UnitEquality Ct -> Either (Ct, UnitEquality) Ct
    foo ct (Left x)    = Left (ct, x)
    foo _  (Right ct') = Right ct'

    -- solvedGiven ct = (ctEvTerm (ctEvidence ct), ct)


unitsOfMeasureSolver uds givens _deriveds wanteds = do
  xs <- lookForUnpacks uds givens wanteds
  if not $ null xs then return $ TcPluginOk [] xs else do
    let (unit_wanteds, _) = partitionEithers $ map (toUnitEquality uds) wanteds
    case unit_wanteds of
      []    -> return $ TcPluginOk [] []
      (_:_) -> do
        (unit_givens , _) <- partitionEithers . map (toUnitEquality uds) <$> mapM zonkCt givens
        sr <- simplifyUnits uds unit_givens
        tcPluginTrace "unitsOfMeasureSolver simplified givens" $ ppr sr
        case sr of
          Impossible eq _ -> reportContradiction uds eq
          Simplified ss   -> do sr' <- simplifyUnits uds $ map (substsUnitEquality (simplifySubst ss)) unit_wanteds
                                tcPluginTrace "unitsOfMeasureSolver simplified wanteds" $ ppr sr'
                                case sr' of
                                  Impossible _eq _ -> return $ TcPluginOk [] [] -- Don't report a contradiction, see #22
                                  Simplified ss'  -> TcPluginOk [ (evMagic uds ct, ct) | eq <- simplifySolved ss', let ct = fromUnitEquality eq ]
                                                         <$> mapM (substItemToCt uds) (filter (isWanted . ctEvidence . siCt) (substsSubst (simplifyUnsubst ss) (simplifySubst ss')))


reportContradiction :: UnitDefs -> UnitEquality -> TcPluginM TcPluginResult
reportContradiction uds eq = TcPluginContradiction . pure <$> fromUnitEqualityForContradiction uds eq

-- See #22 for why we need this
fromUnitEqualityForContradiction :: UnitDefs -> UnitEquality -> TcPluginM Ct
fromUnitEqualityForContradiction uds (UnitEquality ct u v) = case classifyPredType $ ctEvPred $ ctEvidence ct of
    EqPred NomEq _ _ -> return ct
    _ | isGivenCt ct -> newGivenCt  (ctLoc ct) (mkEqPred u' v') (mkFunnyEqEvidence (ctPred ct) u' v')
      | otherwise    -> newWantedCt (ctLoc ct) (mkEqPred u' v')
  where
    u' = reifyUnit uds u
    v' = reifyUnit uds v


substItemToCt :: UnitDefs -> SubstItem -> TcPluginM Ct
substItemToCt uds si
      | isGiven (ctEvidence ct) = newGivenCt loc prd $ evByFiat "units" ty1 ty2
      | otherwise               = newWantedCt loc prd
      where
        prd  = mkEqPred ty1 ty2
        ty1  = mkTyVarTy (siVar si)
        ty2  = reifyUnit uds (siUnit si)
        ct   = siCt si
        loc  = ctLoc ct


lookForUnpacks :: UnitDefs -> [Ct] -> [Ct] -> TcPluginM [Ct]
lookForUnpacks uds givens wanteds = mapM unpackCt unpacks
  where
    unpacks = concatMap collectCt $ givens ++ wanteds

    collectCt ct = collectType ct $ ctEvPred $ ctEvidence ct

    collectType ct (AppTy f s)      = collectType ct f ++ collectType ct s
    collectType ct (TyConApp tc [a])
      | tc == unpackTyCon uds       = case maybeConstant =<< normaliseUnit uds a of
                                        Just xs -> [(ct,a,xs)]
                                        _       -> []
    collectType ct (TyConApp _ as)  = concatMap (collectType ct) as
    collectType ct (FunTy t v)      = collectType ct t ++ collectType ct v
    collectType ct (ForAllTy _ t)   = collectType ct t
    collectType _  _                = [] -- TyVarTy, LitTy from 7.10, plus CastTy and CoercionTy in 8.0

    unpackCt (ct,a,xs) = newGivenCt loc (mkEqPred ty1 ty2) (evByFiat "units" ty1 ty2)
      where
        ty1 = TyConApp (unpackTyCon uds) [a]
        ty2 = mkTyConApp (unitSyntaxPromotedDataCon uds)
               [ typeSymbolKind
               , foldr promoter nil ys
               , foldr promoter nil zs ]
        loc = ctLoc ct

        ys = concatMap (\ (s, i) -> if i > 0 then genericReplicate i s       else []) xs
        zs = concatMap (\ (s, i) -> if i < 0 then genericReplicate (abs i) s else []) xs

    nil = mkTyConApp (promoteDataCon nilDataCon) [typeSymbolKind]

    promoter x t = mkTyConApp cons_tycon [typeSymbolKind, mkStrLitTy x, t]
    cons_tycon = promoteDataCon consDataCon


lookupUnitDefs :: TcPluginM UnitDefs
lookupUnitDefs = do
    md <- lookupModule myModule myPackage
    u <- look md "Unit"
    b <- look md "Base"
    o <- look md "One"
    m <- look md "*:"
    d <- look md "/:"
    e <- look md "^:"
    x <- look md "Unpack"
    i <- look md "UnitSyntax"
    c <- look md "~~"
    return $ UnitDefs u b o m d e x i (getDataCon i ":/") c
  where
    getDataCon u s = case [ dc | dc <- tyConDataCons u, occNameFS (occName (dataConName dc)) == fsLit s ] of
                       [d] -> promoteDataCon d
                       _   -> error $ "lookupUnitDefs/getDataCon: missing " ++ s

    look md s = tcLookupTyCon =<< lookupName md (mkTcOcc s)
    myModule  = mkModuleName "Data.UnitsOfMeasure.Internal"
    myPackage = fsLit "uom-plugin"


-- | Produce bogus evidence for a constraint, including actual
-- equality constraints and our fake '(~~)' equality constraints.
evMagic :: UnitDefs -> Ct -> EvTerm
evMagic uds ct = case classifyPredType $ ctEvPred $ ctEvidence ct of
    EqPred NomEq t1 t2   -> evByFiat "units" t1 t2
    IrredPred t
      | Just (tc, [t1,t2]) <- splitTyConApp_maybe t
      , tc == equivTyCon uds -> mkFunnyEqEvidence t t1 t2
    _                    -> error "evMagic"
