; RUN: %opt -load-pass-plugin=%plugin -passes="custom-dse" -S < %s | %FileCheck %s

; Strategy 1: store to a local alloca that is never read → dead.

define void @write_only_alloca() {
; CHECK-LABEL: @write_only_alloca
; CHECK-NOT: alloca
; CHECK-NOT: store
; CHECK: ret void
  %tmp = alloca i32, align 4
  store i32 42, ptr %tmp, align 4
  ret void
}

define i32 @write_only_alloca_multiple_stores() {
; CHECK-LABEL: @write_only_alloca_multiple_stores
; CHECK-NOT: alloca i32
; CHECK-NOT: store i32 1
; CHECK-NOT: store i32 2
; CHECK: ret i32 0
  %tmp = alloca i32, align 4
  store i32 1, ptr %tmp, align 4
  store i32 2, ptr %tmp, align 4
  ret i32 0
}

; Negative test: alloca IS read — stores must survive.
define i32 @alloca_is_read() {
; CHECK-LABEL: @alloca_is_read
; CHECK: alloca
; CHECK: store i32 99
; CHECK: load
  %tmp = alloca i32, align 4
  store i32 99, ptr %tmp, align 4
  %v = load i32, ptr %tmp, align 4
  ret i32 %v
}
