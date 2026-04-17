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

//===----------------------------------------------------------------------===//
// Strategy 2: Dominated Redundant Store Elimination (MemorySSA)
//===----------------------------------------------------------------------===//

/// Walk from a MemoryDef (store) to its defining access. If the defining
/// access is another MemoryDef that stores to the same location, and the
/// earlier store is dominated by the later one's block (meaning the later
/// store post-dominates all paths from the earlier one), the earlier store
/// is dead.
///
/// This catches patterns like:
///     store i32 1, ptr %p      ; dead — overwritten below
///     store i32 2, ptr %p
///
/// within a basic block or across blocks when dominance allows.

bool CustomDSEPass::eliminateDominatedStores(Function &F,
                                              DominatorTree &DT,
                                              MemorySSA &MSSA,
                                              AliasAnalysis &AA) {
    bool Changed = false;
    MemorySSAUpdater Updater(&MSSA);
    SmallVector<Instruction *, 8> ToDelete;

    for (BasicBlock &BB : F) {
        // Collect stores in this block.
        SmallVector<StoreInst *, 8> Stores;
        for (Instruction &I : BB)
            if (auto *SI = dyn_cast<StoreInst>(&I))
                Stores.push_back(SI);

        for (StoreInst *LaterStore : Stores) {
            // Never eliminate volatile stores.
            if (LaterStore->isVolatile())
                continue;

            MemoryAccess *MA = MSSA.getMemoryAccess(LaterStore);
            if (!MA)
                continue;

            auto *LaterDef = dyn_cast<MemoryDef>(MA);
            if (!LaterDef)
                continue;

            // Walk the defining access chain.
            MemoryAccess *DefAccess = LaterDef->getDefiningAccess();
            if (!DefAccess)
                continue;

            auto *EarlierDef = dyn_cast<MemoryDef>(DefAccess);
            if (!EarlierDef)
                continue;

            // The earlier def must be a store to the same location.
            auto *EarlierStore = dyn_cast<StoreInst>(EarlierDef->getMemoryInst());
            if (!EarlierStore)
                continue;

            // Never eliminate a volatile store.
            if (EarlierStore->isVolatile())
                continue;

            // Check that both stores write to the same memory location.
            MemoryLocation LaterLoc = MemoryLocation::get(LaterStore);
            MemoryLocation EarlierLoc = MemoryLocation::get(EarlierStore);

            if (AA.alias(LaterLoc, EarlierLoc) != AliasResult::MustAlias)
                continue;

            // The earlier store must be in the same block (simplest case)
            // or in a block that dominates this block with no intervening read.
            if (EarlierStore->getParent() != LaterStore->getParent()) {
                // Cross-block: verify dominance and that no read occurs
                // between the two stores on any path.
                if (!DT.dominates(EarlierStore->getParent(),
                                  LaterStore->getParent()))
                    continue;

                // Conservative: skip cross-block elimination if there could be
                // a read on another path. A full implementation would walk
                // MemorySSA uses, but for correctness we restrict to same-block.
                continue;
            }

            // Same block: the earlier store comes before the later store,
            // and MemorySSA says there is no intervening read.
            LLVM_DEBUG(dbgs() << "CustomDSE: dead dominated store: "
                              << *EarlierStore << "\n");
            ToDelete.push_back(EarlierStore);
        }
    }

    for (Instruction *I : ToDelete) {
        MemoryAccess *MA = MSSA.getMemoryAccess(I);
        if (MA) {
            Updater.removeMemoryAccess(MA);
        }
        I->eraseFromParent();
        ++NumDominatedStoresEliminated;
        Changed = true;
    }

    return Changed;
}

//===----------------------------------------------------------------------===//
// Strategy 3: Pre-Lifetime.End Store Elimination
//===----------------------------------------------------------------------===//

/// Eliminate stores to memory that is killed by llvm.lifetime.end before
/// any possible read. Within a basic block, if we see:
///     store ..., ptr %p
///     llvm.lifetime.end(... %p)
/// with no load of %p between them, the store is dead.

bool CustomDSEPass::eliminatePreLifetimeEndStores(Function &F,
                                                    MemorySSA &MSSA) {
    bool Changed = false;
    SmallVector<Instruction *, 8> ToDelete;

    for (BasicBlock &BB : F) {
        // Scan backwards: when we see a lifetime.end, record the pointer.
        // Then, any store to that pointer (before a load) is dead.
        SmallPtrSet<Value *, 4> KilledPtrs;

        for (auto II = BB.rbegin(), IE = BB.rend(); II != IE; ++II) {
            Instruction *I = &*II;

            if (auto *Intr = dyn_cast<IntrinsicInst>(I)) {
                if (Intr->getIntrinsicID() == Intrinsic::lifetime_end) {
                    Value *Ptr = Intr->getArgOperand(1)->stripPointerCasts();
                    KilledPtrs.insert(Ptr);
                    continue;
                }
                if (Intr->getIntrinsicID() == Intrinsic::lifetime_start) {
                    Value *Ptr = Intr->getArgOperand(1)->stripPointerCasts();
                    KilledPtrs.erase(Ptr);
                    continue;
                }
            }

            if (auto *LI = dyn_cast<LoadInst>(I)) {
                // A load from a killed pointer means the store is live.
                Value *Ptr = LI->getPointerOperand()->stripPointerCasts();
                KilledPtrs.erase(Ptr);
                continue;
            }

            if (auto *SI = dyn_cast<StoreInst>(I)) {
                if (SI->isVolatile())
                    continue; // volatile stores are never dead
                Value *Ptr = SI->getPointerOperand()->stripPointerCasts();
                if (KilledPtrs.count(Ptr)) {
                    LLVM_DEBUG(dbgs() << "CustomDSE: pre-lifetime.end dead store: "
                                      << *SI << "\n");
                    ToDelete.push_back(SI);
                }
                continue;
            }

            // A call might read any memory — conservatively clear all.
            if (I->mayReadFromMemory())
                KilledPtrs.clear();
        }
    }

    for (Instruction *I : ToDelete) {
        I->eraseFromParent();
        ++NumPreLifetimeStoresEliminated;
        Changed = true;
    }

    return Changed;
}

//===----------------------------------------------------------------------===//
// Pass Entry Point
//===----------------------------------------------------------------------===//

PreservedAnalyses CustomDSEPass::run(Function &F,
                                      FunctionAnalysisManager &AM) {
    if (F.isDeclaration())
        return PreservedAnalyses::all();

    bool Changed = false;

    // Strategy 1: no dependencies needed.
    Changed |= eliminateWriteOnlyAllocas(F);

    // Strategies 2 & 3 need MemorySSA + DominatorTree + AliasAnalysis.
    auto &DT   = AM.getResult<DominatorTreeAnalysis>(F);
    auto &MSSA = AM.getResult<MemorySSAAnalysis>(F).getMSSA();
    auto &AA   = AM.getResult<AAManager>(F);

    Changed |= eliminateDominatedStores(F, DT, MSSA, AA);
    Changed |= eliminatePreLifetimeEndStores(F, MSSA);

    if (!Changed)
        return PreservedAnalyses::all();

    PreservedAnalyses PA;
    PA.preserve<DominatorTreeAnalysis>();
    return PA;
}

} // namespace custom_dse

//===----------------------------------------------------------------------===//
// Pass Plugin Registration (New Pass Manager)
//===----------------------------------------------------------------------===//

extern "C" LLVM_ATTRIBUTE_WEAK ::llvm::PassPluginLibraryInfo
llvmGetPassPluginInfo() {
    return {
        LLVM_PLUGIN_API_VERSION,
        "CustomDSEPass",
        LLVM_VERSION_STRING,
        [](PassBuilder &PB) {
            // Register the pass so that it can be used with:
            //   opt -load-pass-plugin=./libCustomDSEPass.so \
            //       -passes="custom-dse" input.ll -o output.ll
            PB.registerPipelineParsingCallback(
                [](StringRef Name, FunctionPassManager &FPM,
                   ArrayRef<PassBuilder::PipelineElement>) {
                    if (Name == "custom-dse") {
                        FPM.addPass(custom_dse::CustomDSEPass());
                        return true;
                    }
                    return false;
                });
        }};
}
