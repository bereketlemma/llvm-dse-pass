; RUN: %opt -load-pass-plugin=%plugin -passes="custom-dse" -S < %s | %FileCheck %s

; Write-only array allocas.

define void @write_only_array() {
; CHECK-LABEL: @write_only_array
; CHECK-NOT: alloca
; CHECK-NOT: store
; CHECK: ret void
  %arr = alloca [4 x i32], align 4
  %p0 = getelementptr [4 x i32], ptr %arr, i32 0, i32 0
  %p1 = getelementptr [4 x i32], ptr %arr, i32 0, i32 1
  %p2 = getelementptr [4 x i32], ptr %arr, i32 0, i32 2
  %p3 = getelementptr [4 x i32], ptr %arr, i32 0, i32 3
  store i32 10, ptr %p0, align 4
  store i32 20, ptr %p1, align 4
  store i32 30, ptr %p2, align 4
  store i32 40, ptr %p3, align 4
  ret void
}

; Negative: one element is read.
define i32 @array_element_read() {
; CHECK-LABEL: @array_element_read
; CHECK: alloca
; CHECK: store
; CHECK: load
  %arr = alloca [4 x i32], align 4
  %p0 = getelementptr [4 x i32], ptr %arr, i32 0, i32 0
  store i32 10, ptr %p0, align 4
  %v = load i32, ptr %p0, align 4
  ret i32 %v
}
