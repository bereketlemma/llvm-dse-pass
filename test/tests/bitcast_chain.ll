; RUN: %opt -load-pass-plugin=%plugin -passes="custom-dse" -S < %s | %FileCheck %s

; Write-only alloca accessed through bitcast chain.

define void @bitcast_write_only() {
; CHECK-LABEL: @bitcast_write_only
; CHECK-NOT: alloca
; CHECK-NOT: store
; CHECK: ret void
  %tmp = alloca i64, align 8
  %bc = bitcast ptr %tmp to ptr
  store i32 42, ptr %bc, align 4
  ret void
}

; Negative: bitcast pointer is loaded.
define i32 @bitcast_read() {
; CHECK-LABEL: @bitcast_read
; CHECK: alloca
; CHECK: store
; CHECK: load
  %tmp = alloca i64, align 8
  %bc = bitcast ptr %tmp to ptr
  store i32 42, ptr %bc, align 4
  %v = load i32, ptr %bc, align 4
  ret i32 %v
}
