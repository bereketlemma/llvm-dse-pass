#ifndef CUSTOM_DSE_H
#define CUSTOM_DSE_H

#include "llvm/IR/PassManager.h"

namespace custom_dse {

/// CustomDSEPass - A dead store elimination pass that catches stores
/// missed by LLVM's built-in DSE. Focuses on three patterns:
///
/// 1. Write-only allocas: local allocations whose only uses are stores
///    (the stored values are never read).
///
/// 2. Dominated redundant stores: a store S1 that dominates another
///    store S2 to the same memory location with no intervening read
///    of that location between them (MemorySSA-based analysis).
///
/// 3. Pre-lifetime.end stores: stores to memory that is killed by
///    llvm.lifetime.end before any possible read.
///
class CustomDSEPass : public llvm::PassInfoMixin<CustomDSEPass> {
public:
    llvm::PreservedAnalyses run(llvm::Function &F,
                                llvm::FunctionAnalysisManager &AM);

    static bool isRequired() { return false; }

private:
    /// Eliminate stores to allocas that are never read.
    bool eliminateWriteOnlyAllocas(llvm::Function &F);

    /// Eliminate stores that are overwritten before being read,
    /// using MemorySSA to track memory dependencies.
    bool eliminateDominatedStores(llvm::Function &F,
                                  llvm::DominatorTree &DT,
                                  llvm::MemorySSA &MSSA,
                                  llvm::AliasAnalysis &AA);

    /// Eliminate stores followed by lifetime.end with no intervening read.
    bool eliminatePreLifetimeEndStores(llvm::Function &F,
                                       llvm::MemorySSA &MSSA);
};

} // namespace custom_dse

#endif // CUSTOM_DSE_H
