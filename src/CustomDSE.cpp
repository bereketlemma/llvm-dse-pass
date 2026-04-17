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

namespace custom_dse {

//===----------------------------------------------------------------------===//
// Strategy 1: Write-Only Alloca Elimination
//===----------------------------------------------------------------------===//

/// An alloca is "write-only" if every use is either:
///   - a StoreInst where the alloca is the *pointer* operand, or
///   - a lifetime intrinsic (lifetime.start / lifetime.end), or
///   - a bitcast/GEP chain that itself is only used by stores or lifetimes.
///
/// If no load, call, or escape uses the alloca, all stores to it are dead.

static bool isWriteOnlyUser(const Value *V, SmallPtrSetImpl<const Value *> &Visited) {
    if (!Visited.insert(V).second)
        return true; // already checked, avoid cycles

    for (const User *U : V->users()) {
        if (const auto *SI = dyn_cast<StoreInst>(U)) {
            // Volatile stores have side effects — not dead even if unread.
            if (SI->isVolatile())
                return false;
            // The alloca must be the pointer operand, not the value being stored.
            if (SI->getValueOperand() == V)
                return false; // address escapes as a stored value
            continue;
        }

        if (const auto *II = dyn_cast<IntrinsicInst>(U)) {
            if (II->getIntrinsicID() == Intrinsic::lifetime_start ||
                II->getIntrinsicID() == Intrinsic::lifetime_end)
                continue;

            // memset destination is a write — OK if alloca is dest (arg 0).
            if (II->getIntrinsicID() == Intrinsic::memset) {
                if (II->getArgOperand(0)->stripPointerCasts() == V)
                    continue; // writing to the alloca — still write-only
                return false;
            }

            // memcpy/memmove: dest (arg 0) is write, src (arg 1) is read.
            if (II->getIntrinsicID() == Intrinsic::memcpy ||
                II->getIntrinsicID() == Intrinsic::memmove) {
                if (II->getArgOperand(0)->stripPointerCasts() == V)
                    continue; // alloca is destination — write only
                return false; // alloca is source — being read
            }

            return false; // some other intrinsic reads the memory
        }

        // Transparent pointer casts — recurse into their users.
        if (isa<BitCastInst>(U) || isa<GetElementPtrInst>(U) ||
            isa<AddrSpaceCastInst>(U)) {
            if (!isWriteOnlyUser(U, Visited))
                return false;
            continue;
        }

        // Any other use (load, call, phi, etc.) means the value may be read.
        return false;
    }

    return true;
}

bool CustomDSEPass::eliminateWriteOnlyAllocas(Function &F) {
    SmallVector<AllocaInst *, 16> Allocas;
    for (auto &I : F.getEntryBlock())
        if (auto *AI = dyn_cast<AllocaInst>(&I))
            Allocas.push_back(AI);

    bool Changed = false;

    for (AllocaInst *AI : Allocas) {
        SmallPtrSet<const Value *, 16> Visited;
        if (!isWriteOnlyUser(AI, Visited))
            continue;

        // Collect all stores and lifetime intrinsics to delete.
        SmallVector<Instruction *, 8> ToDelete;
        SmallVector<Value *, 4> Worklist;
        Worklist.push_back(AI);

        SmallPtrSet<Value *, 16> Seen;
        while (!Worklist.empty()) {
            Value *V = Worklist.pop_back_val();
            if (!Seen.insert(V).second)
                continue;
            for (User *U : V->users()) {
                if (auto *SI = dyn_cast<StoreInst>(U)) {
                    ToDelete.push_back(SI);
                } else if (auto *II = dyn_cast<IntrinsicInst>(U)) {
                    ToDelete.push_back(II);
                } else if (isa<BitCastInst>(U) || isa<GetElementPtrInst>(U) ||
                           isa<AddrSpaceCastInst>(U)) {
                    Worklist.push_back(U);
                    ToDelete.push_back(cast<Instruction>(U));
                }
            }
        }

        // Delete in reverse order to avoid use-before-delete issues.
        for (auto *I : llvm::reverse(ToDelete)) {
            LLVM_DEBUG(dbgs() << "CustomDSE: erasing write-only user: " << *I << "\n");
            I->eraseFromParent();
            ++NumWriteOnlyStoresEliminated;
        }

        AI->eraseFromParent();
        Changed = true;
    }

    return Changed;
}
