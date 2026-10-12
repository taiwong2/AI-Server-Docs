' dsh-proxy.vbs: keep the DSH model proxy (bin\dsh-proxy.mjs, 127.0.0.1:1235) running with no window.
' Started at logon by the "DSH Proxy" scheduled task; restarts node 10 s after it exits.
Set sh = CreateObject("WScript.Shell")
root = sh.ExpandEnvironmentStrings("%USERPROFILE%") & "\deepseek-harness"
Do
  sh.Run "node """ & root & "\bin\dsh-proxy.mjs""", 0, True
  WScript.Sleep 10000
Loop
