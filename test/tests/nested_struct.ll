; RUN: %opt -load-pass-plugin=%plugin -passes="custom-dse" -S < %s | %FileCheck %s

; Nested struct with multiple fields — all write-only.

%struct.inner = type { i32, i32 }
%struct.outer = type { %struct.inner, i64 }

define void @nested_struct_write_only() {
; CHECK-LABEL: @nested_struct_write_only
; CHECK-NOT: alloca
; CHECK-NOT: store
; CHECK: ret void
  %s = alloca %struct.outer, align 8
  %inner = getelementptr %struct.outer, ptr %s, i32 0, i32 0
  %a = getelementptr %struct.inner, ptr %inner, i32 0, i32 0
  %b = getelementptr %struct.inner, ptr %inner, i32 0, i32 1
  %c = getelementptr %struct.outer, ptr %s, i32 0, i32 1
  store i32 1, ptr %a, align 4
  store i32 2, ptr %b, align 4
  store i64 3, ptr %c, align 8
  ret void
}

; Only the outer field is read — all stores must survive (conservative).
define i64 @nested_partial_read() {
; CHECK-LABEL: @nested_partial_read
; CHECK: alloca
; CHECK: store
; CHECK: load
  %s = alloca %struct.outer, align 8
  %inner = getelementptr %struct.outer, ptr %s, i32 0, i32 0
  %a = getelementptr %struct.inner, ptr %inner, i32 0, i32 0
  %c = getelementptr %struct.outer, ptr %s, i32 0, i32 1
  store i32 1, ptr %a, align 4
  store i64 3, ptr %c, align 8
  %v = load i64, ptr %c, align 8
  ret i64 %v
}
