#!/bin/bash
# Run inside launcher pod to debug mpirun
set +e
echo "== hostfile =="
cat /etc/mpi/hostfile
echo
echo "== hostname =="
hostname -f
hostname -i
echo
echo "== verbose mpirun (25s timeout) =="
timeout 25 mpirun \
  --allow-run-as-root \
  --hostfile /etc/mpi/hostfile \
  -np 2 \
  --mca plm_base_verbose 10 \
  --mca oob_base_verbose 5 \
  --mca plm_rsh_no_tree_spawn 1 \
  hostname 2>&1 | tail -80
echo "== exit=$? =="
