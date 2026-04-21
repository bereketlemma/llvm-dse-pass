; RUN: %opt -load-pass-plugin=%plugin -passes="custom-dse" -S < %s | %FileCheck %s

; Ensure the pass handles different types and widths correctly.

define void @write_only_i8() {
; CHECK-LABEL: @write_only_i8
; CHECK-NOT: alloca
; CHECK-NOT: store
  %tmp = alloca i8, align 1
  store i8 65, ptr %tmp, align 1
  ret void
}

define void @write_only_i64() {
; CHECK-LABEL: @write_only_i64
; CHECK-NOT: alloca
; CHECK-NOT: store
  %tmp = alloca i64, align 8
  store i64 999, ptr %tmp, align 8
  ret void
}

define void @write_only_float() {
; CHECK-LABEL: @write_only_float
; CHECK-NOT: alloca
; CHECK-NOT: store
  %tmp = alloca float, align 4
  store float 3.14, ptr %tmp, align 4
  ret void
}

define void @write_only_double() {
; CHECK-LABEL: @write_only_double
; CHECK-NOT: alloca
; CHECK-NOT: store
  %tmp = alloca double, align 8
  store double 2.718, ptr %tmp, align 8
  ret void
}

define void @write_only_ptr() {
; CHECK-LABEL: @write_only_ptr
; CHECK-NOT: alloca
; CHECK-NOT: store
  %tmp = alloca ptr, align 8
  store ptr null, ptr %tmp, align 8
  ret void
}

; Overwrite across types — i32 overwritten.
define void @overwrite_i64(ptr %p) {
; CHECK-LABEL: @overwrite_i64
; CHECK-NOT: store i64 111
; CHECK: store i64 222
  store i64 111, ptr %p, align 8
  store i64 222, ptr %p, align 8
  ret void
}
