; RUN: %opt -load-pass-plugin=%plugin -passes="custom-dse" -S < %s | %FileCheck %s

; Volatile stores must NEVER be eliminated regardless of deadness.

define void @volatile_write_only() {
; CHECK-LABEL: @volatile_write_only
; CHECK: alloca
; CHECK: store volatile i32 42
; CHECK: ret void
  %tmp = alloca i32, align 4
  store volatile i32 42, ptr %tmp, align 4
  ret void
}

define void @volatile_overwrite(ptr %p) {
; CHECK-LABEL: @volatile_overwrite
; CHECK: store volatile i32 1, ptr %p
; CHECK: store i32 2, ptr %p
; CHECK: ret void
  store volatile i32 1, ptr %p, align 4
  store i32 2, ptr %p, align 4
  ret void
}
