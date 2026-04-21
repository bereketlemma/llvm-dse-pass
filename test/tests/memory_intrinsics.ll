; RUN: %opt -load-pass-plugin=%plugin -passes="custom-dse" -S < %s | %FileCheck %s

; Stores followed by memset to the same location — earlier store is dead
; if memset completely covers it. (Conservative: we don't eliminate these
; in Strategy 2 since MemorySSA treats memset as a MemoryDef, not StoreInst.)

declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)
declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)

; Write-only alloca that only has memset — should be eliminated.
define void @memset_write_only() {
; CHECK-LABEL: @memset_write_only
; CHECK-NOT: alloca
; CHECK: ret void
  %buf = alloca [64 x i8], align 1
  call void @llvm.memset.p0.i64(ptr %buf, i8 0, i64 64, i1 false)
  ret void
}

; Negative: alloca is read via memcpy source.
define void @memcpy_reads_alloca(ptr %dst) {
; CHECK-LABEL: @memcpy_reads_alloca
; CHECK: alloca
; CHECK: store
; CHECK: memcpy
  %buf = alloca [4 x i8], align 1
  store i8 65, ptr %buf, align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %dst, ptr %buf, i64 4, i1 false)
  ret void
}

; Alloca used only as memcpy destination — write-only, eliminate.
define void @memcpy_dst_only(ptr %src) {
; CHECK-LABEL: @memcpy_dst_only
; CHECK-NOT: alloca
; CHECK: ret void
  %buf = alloca [4 x i8], align 1
  call void @llvm.memcpy.p0.p0.i64(ptr %buf, ptr %src, i64 4, i1 false)
  ret void
}
