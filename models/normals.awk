# Read an OBJ, compute area-weighted vertex normals, write it back with them.
function idx(tok,  parts, i) { split(tok, parts, "/"); i = parts[1] + 0; return i > 0 ? i : nv + i + 1 }
/^v[ \t]/ { nv++; vx[nv]=$2; vy[nv]=$3; vz[nv]=$4; next }
/^f[ \t]/ {
  nf++; n = NF - 1
  fc[nf] = n
  for (k = 1; k <= n; k++) f[nf, k] = idx($(k+1))
  next
}
END {
  for (i = 1; i <= nf; i++)
    for (k = 2; k < fc[i]; k++) {
      a = f[i,1]; b = f[i,k]; c = f[i,k+1]
      ux = vx[b]-vx[a]; uy = vy[b]-vy[a]; uz = vz[b]-vz[a]
      wx = vx[c]-vx[a]; wy = vy[c]-vy[a]; wz = vz[c]-vz[a]
      cx = uy*wz - uz*wy; cy = uz*wx - ux*wz; cz = ux*wy - uy*wx
      nx[a]+=cx; ny[a]+=cy; nz[a]+=cz
      nx[b]+=cx; ny[b]+=cy; nz[b]+=cz
      nx[c]+=cx; ny[c]+=cy; nz[c]+=cz
    }
  printf "o %s\n", NAME
  for (i = 1; i <= nv; i++) printf "v %.6g %.6g %.6g\n", vx[i], vy[i], vz[i]
  for (i = 1; i <= nv; i++) {
    m = sqrt(nx[i]^2 + ny[i]^2 + nz[i]^2); if (m == 0) m = 1
    printf "vn %.4g %.4g %.4g\n", nx[i]/m, ny[i]/m, nz[i]/m
  }
  for (i = 1; i <= nf; i++) {
    printf "f"
    for (k = 1; k <= fc[i]; k++) printf " %d//%d", f[i,k], f[i,k]
    printf "\n"
  }
}
