#!/bin/bash
# Run inside launcher pod; writes debug result to /tmp/mpi_debug.log in BACKGROUND.
# Caller should sleep, then cat /tmp/mpi_debug.log separately.
set +e
(
  echo "== hostfile =="
  cat /etc/mpi/hostfile
  echo
  echo "== hostname =="
  hostname -f
  hostname -i
  echo
  echo "== verbose mpirun =="
  timeout 25 mpirun \
    --allow-run-as-root \
    --hostfile /etc/mpi/hostfile \
    -np 2 \
    --mca plm_base_verbose 10 \
    --mca oob_base_verbose 5 \
    --mca plm_rsh_no_tree_spawn 1 \
    hostname 2>&1 | tail -120
  echo "== exit=$? =="
  echo "== DONE =="
) > /tmp/mpi_debug.log 2>&1 &
echo "pid=$!"
