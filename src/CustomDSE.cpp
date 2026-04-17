//===-- CustomDSE.cpp - Custom Dead Store Elimination Pass ----------------===//
//
// A supplemental dead store elimination pass targeting patterns that
// LLVM's built-in DSE (-O2) may leave behind. Operates on the new pass
// manager and relies on MemorySSA + DominatorTree for correctness.
//
// Three elimination strategies:
//   1. Write-only allocas  (stores to never-read locals)
//   2. Dominated stores    (overwritten before read, via MemorySSA walk)
//   3. Pre-lifetime.end    (stores killed by lifetime.end)
//
//===----------------------------------------------------------------------===//

#include "CustomDSE.h"

#include "llvm/ADT/SmallVector.h"
#include "llvm/ADT/Statistic.h"
#include "llvm/Analysis/AliasAnalysis.h"
#include "llvm/Analysis/MemorySSA.h"
#include "llvm/Analysis/MemorySSAUpdater.h"
#include "llvm/IR/Dominators.h"
#include "llvm/IR/Function.h"
#include "llvm/IR/Instructions.h"
#include "llvm/IR/IntrinsicInst.h"
#include "llvm/Passes/PassBuilder.h"
#include "llvm/Passes/PassPlugin.h"
#include "llvm/Support/Debug.h"
#include "llvm/Support/raw_ostream.h"

using namespace llvm;

#define DEBUG_TYPE "custom-dse"

STATISTIC(NumWriteOnlyStoresEliminated,
          "Number of stores to write-only allocas eliminated");
STATISTIC(NumDominatedStoresEliminated,
          "Number of dominated dead stores eliminated");
STATISTIC(NumPreLifetimeStoresEliminated,
          "Number of pre-lifetime.end stores eliminated");
