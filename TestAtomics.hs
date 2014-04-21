import Control.Concurrent
import Data.Atomics.Counter
import Data.Atomics
import Data.IORef
import Control.Monad
import GHC.Conc
import Control.Exception(evaluate)
import qualified Data.Set as Set
import Data.List

main = do
    testCounterOverflow
    testConsistentSuccessFailure
    counterTest
{-
    testCAS_ABA_0
    testCAS_ABA_0_modAfterAtomicMod
    testCAS_ABA_0_modBefAtomicMod
    testCAS_ABA_1
    testCAS_ABA_2
    testCAS_ABA_3

-}
cHUNK_SIZE = 32
maxInt = maxBound :: Int
minInt = minBound :: Int
testCounterOverflow = do
    let ourMod = mod -- or something more fancy?
    cntr <- newCounter (maxInt - (cHUNK_SIZE `div` 2)) 
    spanningCntr <- replicateM cHUNK_SIZE (incrCounter 1 cntr)
    -- make sure our test is working
    if all (>0) spanningCntr || all (<0) spanningCntr
        then error "Sequence meant to span maxBound of counter not actually spanning"
        else return ()

    let l = map (`ourMod` cHUNK_SIZE) spanningCntr
        l' = (dropWhile (/= 0) l) ++ (takeWhile (/= 0) l)

    -- (1) test that we overflow the counter without any breaks and our mod function is working properly:
    if l' == [0..(cHUNK_SIZE - 1)]
        then putStrLn $ "OK"
        else error $ "Uh Oh: "++(show l')

    -- (2) test that Ints and counter overflow in exactly the same way
    let spanningInts = take cHUNK_SIZE $ iterate (+1) (maxInt - (cHUNK_SIZE `div` 2) + 1) 
    if spanningInts == spanningCntr 
        then putStrLn "OK"
        else do putStrLn $ "Ints overflow differently than counter: "
                putStrLn $ "Int: "++(show spanningInts)
                putStrLn $ "Counter: "++(show spanningCntr)
                error "Fail"

    -- We don't use this property
    cntr2 <- newCounter maxBound
    mbnd <- incrCounter 1 cntr2
    if mbnd == minBound
        then putStrLn "OK"
        else error $ "Incrementing counter at maxbound didn't yield minBound"

    -- (3) test subtraction across boundary: count - newFirstIndex, for window spanning boundary.
    cntr3 <- newCounter (maxBound - 1)
    let ls = take 30 $ iterate (+1) $ maxBound - 10
    cs <- mapM (\l-> fmap (subtract l) $ incrCounter 1 cntr3) ls
    if cs == replicate 30 10
        then putStrLn "OK"
        else error $ "Derp. We don't know how subtraction works: "++(show cs)
    -- (4) readIORef before fetchAndAdd w/ barriers


-- Test these assumptions:
--   1) If a CAS fails in thread 1 then another CAS (in thread 2, say) succeeded
--   2) In the case that thread 1's CAS failed, the ticket returned with (False,tk) will contain that newly-written value from thread 2
testConsistentSuccessFailure = do
    var <- newIORef "0"

    sem <- newIORef (0::Int)
    outs <- replicateM 2 newEmptyMVar 

    forkSync sem 2 $ test "a" var (outs!!0)
    forkSync sem 2 $ test "b" var (outs!!1)

    mapM takeMVar outs >>= examine
       -- w/r/t (2) above: we only try to find an element read along with False
       -- which wasn't sent by another thread, which isn't ideal
 where attempts = 100000
       test tag var out = do
         
         res <- forM [(1::Int)..attempts] $ \x-> do
                    let str = (tag++(show x))
                    tk <- readForCAS var
                    (b,tk') <- casIORef var tk str
                    return (if b then str else peekTicket tk' , b)
         putMVar out res

       examine [res1, res2] = do
         -- any failures in either should be marked as successes in the other
         let (successes1,failures1) = (\(x,y)-> (Set.fromList $ map fst x, map fst y)) $ partition snd res1
             (successes2,failures2) = (\(x,y)-> (Set.fromList $ map fst x, map fst y)) $ partition snd res2
             ok1 = all (flip Set.member successes2) failures1
             ok2 = all (flip Set.member successes1) failures2
         if ok1 && ok2
             then if length failures1 < (attempts `div` 6) || length failures2 < (attempts `div` 6) 
                    then error "There was not enough contention to trust test. Please retry."
                    else putStrLn "OK"
             else do print res1
                     print res2
                     error "FAILURE!"

                   
-- forkSync :: IORef Int -> Int -> IO a -> IO ThreadId
forkSync sem target io = 
    forkIO $ (busyWait >> io)
  where busyWait =
           atomicModifyIORef' sem (\n-> (n+1,())) >> wait
        wait = do
            n <- readIORef sem
            unless (n == target) wait
    

counterTest = do
    n0 <- testAtomicCount newCounter readCounter incrCounter
    n1 <- testAtomicCount newMVar takeMVar (\n v-> modifyMVar_ v (evaluate . (+1)) )
    if n0 /= n1
        then putStrLn $ "Counter broken: expecting "++(show n1)++" got "++(show n0)
        else putStrLn "OK"

testAtomicCount new read incr = do
  let n = 1000000
  procs <- getNumCapabilities

  counter <- new (1::Int)
  dones <- replicateM procs newEmptyMVar ; starts <- replicateM procs newEmptyMVar
  mapM_ (\(start1,done1)-> forkIO $ takeMVar start1 >> replicateM_ (n `div` procs) (incr 1 counter) >> putMVar done1 ()) $ zip starts dones
  mapM_ (\v-> putMVar v ()) starts ; mapM_ (\v-> takeMVar v) dones
  
  read counter

-- test ABA issue with these three cases:
--   ()
--   Bool
--       {-# NOINLINE True #-}
--   let true = True



-- returns False
testCAS_ABA_0 = do
    a <- newIORef ()
    ta <- readForCAS a
    atomicModifyIORef' a (\u-> (u,u))
    (res, _) <- casIORef a ta () 
    print res
{- same
testCAS_ABA_0_nonstrict = do
    a <- newIORef ()
    ta <- readForCAS a
    atomicModifyIORef a (\u-> (u,u))
    (res, _) <- casIORef a ta () 
    print res
testCAS_ABA_0_u = do
    a <- newIORef ()
    ta <- readForCAS a
    atomicModifyIORef' a (const ((),()))
    (res, _) <- casIORef a ta () 
    print res
testCAS_ABA_0_sameu = do
    let {-# NOINLINE u #-} 
        u = ()
    a <- newIORef u
    ta <- readForCAS a
    atomicModifyIORef' a (const (u,u))
    (res, _) <- casIORef a ta () 
    print res
-}

-- returns True
testCAS_ABA_1 = do
    a <- newIORef ()
    ta <- readForCAS a
    modifyIORef a (const ())   -- i.e. readIORef >> writeIORef
    (res, _) <- casIORef a ta () 
    print res

{- same
testCAS_ABA_1_casMod = do
    a <- newIORef ()
    ta <- readForCAS a
    atomicModifyIORefCAS_ a id
    (res, _) <- casIORef a ta () 
    print res
testCAS_ABA_1_id = do
    a <- newIORef ()
    ta <- readForCAS a
    modifyIORef a id   -- i.e. readIORef >> writeIORef
    (res, _) <- casIORef a ta () 
    print res
-}

-- returns True
-- ... so the issue isn't re-ordering of readForCas and the read in modifyIORef
-- in fact, no combination of the barriers provided seem to work.
testCAS_ABA_2 = do
    a <- newIORef ()
    ta <- readForCAS a
    loadLoadBarrier
    modifyIORef a (const ())   -- i.e. readIORef >> writeIORef
    (res, _) <- casIORef a ta () 
    print res

testCAS_ABA_3 = do
    barrier <- newIORef ()

    a <- newIORef ()
    ta <- readForCAS a

    atomicModifyIORef' barrier (\u-> (u,u))  -- just a barrier
    modifyIORef a (const ())   -- i.e. readIORef >> writeIORef
    atomicModifyIORef' barrier (\u-> (u,u))  -- just a barrier
    
    (res, _) <- casIORef a ta () 
    print res

-- INTERESTING!: /adding/ the modifyIORef /after/ the atomicModifyIORef causes this to return True!
testCAS_ABA_0_modAfterAtomicMod = do
    barrier <- newIORef ()

    a <- newIORef ()
    ta <- readForCAS a

    atomicModifyIORef' a (\u-> (u,u))
    modifyIORef a (const ())   -- i.e. readIORef >> writeIORef
    
    (res, _) <- casIORef a ta () 
    print res

-- ...whereas this one returns False again
testCAS_ABA_0_modBefAtomicMod = do
    barrier <- newIORef ()

    a <- newIORef ()
    ta <- readForCAS a

    modifyIORef a (const ())   -- i.e. readIORef >> writeIORef
    atomicModifyIORef' a (\u-> (u,u))
    
    (res, _) <- casIORef a ta () 
    print res
