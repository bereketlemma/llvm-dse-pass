; RUN: %opt -load-pass-plugin=%plugin -passes="custom-dse" -S < %s | %FileCheck %s

; An alloca whose address is passed to a function may be read
; by that function — store must NOT be eliminated.

declare void @external_func(ptr)

define void @alloca_escapes_to_call() {
; CHECK-LABEL: @alloca_escapes_to_call
; CHECK: alloca
; CHECK: store i32 42
; CHECK: call void @external_func
  %tmp = alloca i32, align 4
  store i32 42, ptr %tmp, align 4
  call void @external_func(ptr %tmp)
  ret void
}

; An alloca stored into another pointer escapes.
define void @alloca_stored_as_value(ptr %out) {
; CHECK-LABEL: @alloca_stored_as_value
; CHECK: alloca
; CHECK: store
  %tmp = alloca i32, align 4
  store ptr %tmp, ptr %out, align 8
  ret void
}
