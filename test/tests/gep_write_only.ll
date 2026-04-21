; RUN: %opt -load-pass-plugin=%plugin -passes="custom-dse" -S < %s | %FileCheck %s

; Write-only alloca accessed through GEP — should still be eliminated.

%struct.pair = type { i32, i32 }

define void @write_only_struct_alloca() {
; CHECK-LABEL: @write_only_struct_alloca
; CHECK-NOT: alloca
; CHECK-NOT: store
; CHECK: ret void
  %s = alloca %struct.pair, align 4
  %a = getelementptr %struct.pair, ptr %s, i32 0, i32 0
  %b = getelementptr %struct.pair, ptr %s, i32 0, i32 1
  store i32 1, ptr %a, align 4
  store i32 2, ptr %b, align 4
  ret void
}

; Negative: one field is read through GEP.
define i32 @struct_field_read() {
; CHECK-LABEL: @struct_field_read
; CHECK: alloca
; CHECK: store
; CHECK: load
  %s = alloca %struct.pair, align 4
  %a = getelementptr %struct.pair, ptr %s, i32 0, i32 0
  store i32 7, ptr %a, align 4
  %v = load i32, ptr %a, align 4
  ret i32 %v
}
