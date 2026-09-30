# 1秒ごとにノード全体の「運ぶ・戻す・書く」を記録する
# 列: 経過秒 / 受信MB/s / CPU全体% / iowait% / 一番忙しいコア% / ディスク書込MB/s
#     / 一番忙しいスレッド% とその名前（コアを渡り歩いても1人の働きがわかる）
function rd(   line, f, a, i, tot, cmd, p, rest, name) {
  f = "/proc/uptime"; getline line < f; close(f); split(line, a, " "); up = a[1]
  rx = 0; f = "/proc/net/dev"
  while ((getline line < f) > 0) {
    gsub(":", " ", line); split(line, a, " ")
    if (a[1] ~ /^(ens|eth)/) rx += a[2]
  }
  close(f)
  f = "/proc/stat"
  while ((getline line < f) > 0) {
    split(line, a, " ")
    if (a[1] ~ /^cpu/) {
      tot = 0; for (i = 2; i <= 9; i++) tot += a[i]
      T[a[1]] = tot; I[a[1]] = a[5]; W[a[1]] = a[6]
    }
  }
  close(f)
  wr = 0; f = "/proc/diskstats"
  while ((getline line < f) > 0) {
    split(line, a, " ")
    if (a[3] ~ /^nvme[0-9]+n1$/) wr += a[10]
  }
  close(f)
  # スレッドごとの CPU 時間（tick）。/proc/<pid>/task/<tid>/stat の utime+stime
  delete J; cmd = "cat /proc/[0-9]*/task/[0-9]*/stat 2>/dev/null"
  while ((cmd | getline line) > 0) {
    split(line, a, " "); p = a[1]
    name = substr(line, index(line, "(") + 1); name = substr(name, 1, index(name, ")") - 1)
    rest = substr(line, index(line, ") ") + 2); split(rest, a, " ")
    J[p] = a[12] + a[13]; N[p] = name
  }
  close(cmd)
}
function save(   k) {
  pup = up; prx = rx; pwr = wr
  for (k in T) { PT[k] = T[k]; PI[k] = I[k]; PW[k] = W[k] }
  delete PJ; for (k in J) PJ[k] = J[k]
}
function pct(k, what,   dt) {
  dt = T[k] - PT[k]; if (dt <= 0) return 0
  if (what == "busy") return 100 * (dt - (I[k] - PI[k]) - (W[k] - PW[k])) / dt
  return 100 * (W[k] - PW[k]) / dt
}
BEGIN {
  rd(); save(); t0 = up
  print "sec\trx_MBps\tcpu%\tiowait%\tmaxcore%\tdisk_w_MBps\ttopthr%\ttopthr"
  while (1) {
    system("sleep 1"); rd()
    d = up - pup; mc = 0; mt = 0; mn = "-"
    for (k in T) if (k != "cpu") { v = pct(k, "busy"); if (v > mc) mc = v }
    for (k in J) if (k in PJ) { v = (J[k] - PJ[k]) / d; if (v > mt) { mt = v; mn = N[k] } }
    printf "%d\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%s\n", up - t0, (rx - prx) / d / 1e6, pct("cpu", "busy"), pct("cpu", "wait"), mc, (wr - pwr) * 512 / d / 1e6, mt, mn
    fflush(); save()
  }
}
