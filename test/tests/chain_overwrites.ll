; RUN: %opt -load-pass-plugin=%plugin -passes="custom-dse" -S < %s | %FileCheck %s

; Chain of overwrites — only the last store should survive.

define void @triple_overwrite(ptr %p) {
; CHECK-LABEL: @triple_overwrite
; CHECK-NOT: store i32 1
; CHECK-NOT: store i32 2
; CHECK: store i32 3, ptr %p
; CHECK: ret void
  store i32 1, ptr %p, align 4
  store i32 2, ptr %p, align 4
  store i32 3, ptr %p, align 4
  ret void
}

; Two independent pointers — no elimination across them.
define void @independent_ptrs(ptr noalias %p, ptr noalias %q) {
; CHECK-LABEL: @independent_ptrs
; CHECK: store i32 1, ptr %p
; CHECK: store i32 2, ptr %q
  store i32 1, ptr %p, align 4
  store i32 2, ptr %q, align 4
  ret void
}

; Multiple write-only allocas.
define void @multi_write_only_allocas() {
; CHECK-LABEL: @multi_write_only_allocas
; CHECK-NOT: alloca
; CHECK-NOT: store
; CHECK: ret void
  %a = alloca i32, align 4
  %b = alloca i64, align 8
  %c = alloca float, align 4
  store i32 1, ptr %a, align 4
  store i64 2, ptr %b, align 8
  store float 3.0, ptr %c, align 4
  ret void
}
