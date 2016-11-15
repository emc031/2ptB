#!/bin/bash

#! sbatch directives begin here ###############################
#SBATCH --job-name=Hl_2pt
#SBATCH --output=./out/Hl_2pt-%A.out
#SBATCH --error=./out/Hl_2pt-%A.err
#SBATCH -A DIRAC-DP019
#SBATCH --nodes=1
##SBATCH --mem=MaxMemPerNode
#! How many (MPI) tasks will there be in total? (<= nodes*16)
#SBATCH --ntasks=16
#SBATCH --time=01:30:00
##SBATCH --mail-type=NONE
##SBATCH --no-requeue

#! Do not change:
#SBATCH -p sandybridge

#! Number of nodes and tasks per node allocated by SLURM (do not change):
numnodes=$SLURM_JOB_NUM_NODES
numtasks=$SLURM_NTASKS
mpi_tasks_per_node=$(echo "$SLURM_TASKS_PER_NODE" | sed -e  's/^\([0-9][0-9]*\).*$/\1/')
#! ############################################################
#! Modify the settings below to specify the application's environment, location 
#! and launch method:

#! Optionally modify the environment seen by the application
#! (note that SLURM reproduces the environment at submission irrespective of ~/.bashrc):
. /etc/profile.d/modules.sh                # Leave this line (enables the module command)
module purge                               # Removes all modules still loaded
module load default-impi                   # REQUIRED - loads the basic environment

#! Insert additional module load commands after this line if needed:

Lt=96  # Time extent.
nsrc=16  # Number of source times. #SET TO 16 WHEN READY
dsrc=$((Lt/nsrc))  # Spacing of source times.
cfg1=$1

# Generates source times.
gen_src()
{
  local cfg=$1
  local src_start=$(((19*(cfg/5)) % dsrc))  # Magic formula.
  for i in $(seq 0 $((nsrc-1))); do
    echo $((src_start + i*dsrc));
  done
}

#convert light propagators from scidac to binary
run_convert()
{
  #now i'm also copying over the scidac propagators one by one from dc-sant2,
  #since i don't have permission to do all the mkdirs shit like that that lime_unpack
  #wants to do over there.

  local convert="./convert-scidac-to-binary.sh"
  #local cfg=$1
  cfg=$1
  for src in $(gen_src $cfg); do
        echo "copying $cfg t$src to temp/"
	cp "/lustre2/dc-sant2/fine_lattice/etas_fine_propagators/l3296f211b630m0074m037m440-coul.${cfg}_wallprop_m0.0376_th0.0_t${src}" $temp

	echo "converting $cfg t$src"
	$convert $temp "l3296f211b630m0074m037m440-coul.${cfg}_wallprop_m0.0376_th0.0_t${src}"
	#binary files saved in hl-2pt-exec/temp/, set this in convert-scidac-to-binary.sh
  done
}

#generate input files, and run nrqcd code
run_nrqcd_parallel()
{
  local application="${root}/heavyq.exe"
  cfg=$1
  for src in $(gen_src $cfg); do
	infile="${root}/in/nrqcd_in_${cfg}_t${src}.xml"
	outfile="${root}/out/bumph-${cfg}.${src}"

	python ${root}/in/gen-nrqcd-input.py $cfg $src > $infile

	echo "running $cfg t$src"
	srun --exclusive -N1 -n1 $application $infile ulimit -s 200000 > $outfile &
  done
}

cleanup ()
{
  local cfg=$1
  for src in $(gen_src $cfg); do    
    rm "${temp}/l3296f211b630m0074m037m440-coul.${cfg}_wallprop_m0.0376_th0.0_t${src}"
    rm "${temp}/l3296f211b630m0074m037m440-coul.${cfg}_wallprop_m0.0376_th0.0_t${src}.binary"
    rm "${temp}/l3296f211b630m0074m037m440-coul.${cfg}_wallprop_m0.0376_th0.0_t${src}.source.binary"
   
  done
}

#! Full path to application executable:
root="."
temp="/lustre5/dc-mcle2/BtoD/hl-2pt-exec/temp/"

#! Work directory (i.e. where the job will run):
workdir="." #"$SLURM_SUBMIT_DIR"  # The value of SLURM_SUBMIT_DIR sets workdir to the directory
                             # in which sbatch is run.

#! Are you using OpenMP (NB this is unrelated to OpenMPI)? If so increase this
#! safe value to no more than 16:
export OMP_NUM_THREADS=1

#! Number of MPI tasks to be started by the application per node and in total (do not change):
np=$[${numnodes}*${mpi_tasks_per_node}]

#! The following variables define a sensible pinning strategy for Intel MPI tasks -
#! this should be suitable for both pure MPI and hybrid MPI/OpenMP jobs:
export I_MPI_PIN_DOMAIN=omp:compact # Domains are $OMP_NUM_THREADS cores in size
export I_MPI_PIN_ORDER=scatter # Adjacent domains have minimal sharing of caches/sockets
#! Notes:
#! 1. These variables influence Intel MPI only.
#! 2. Domains are non-overlapping sets of cores which map 1-1 to MPI tasks.
#! 3. I_MPI_PIN_PROCESSOR_LIST is ignored if I_MPI_PIN_DOMAIN is set.
#! 4. If MPI tasks perform better when sharing caches/sockets, try I_MPI_PIN_ORDER=compact.


#! Uncomment one choice for CMD below (add mpirun/mpiexec options if necessary):

#! Choose this for a MPI code (possibly using OpenMP) using Intel MPI.
#CMD="mpirun -ppn $mpi_tasks_per_node -np $np $application $options"

#! Choose this for a pure shared-memory OpenMP parallel program on a single node:
#! (OMP_NUM_THREADS threads will be created):
#CMD="$application $options"

#! Choose this for a MPI code (possibly using OpenMP) using OpenMPI:
#CMD="mpirun -npernode $mpi_tasks_per_node -np $np $application $options"


###############################################################
### You should not have to change anything below this line ####
###############################################################

cd $workdir
echo -e "Changed directory to `pwd`.\n"

JOBID=$SLURM_JOB_ID

echo -e "JobID: $JOBID\n======"
echo "Time: `date`"
echo "Running on master node: `hostname`"
echo "Current directory: `pwd`"

if [ "$SLURM_JOB_NODELIST" ]; then
  #! Create a machine file:
  export NODEFILE=`generate_pbs_nodefile`
  cat $NODEFILE | uniq > out/machine.file.$JOBID
  echo -e "\nNodes allocated:\n================"
  echo `cat machine.file.$JOBID | sed -e 's/\..*$//g'`
  mv machine.file.${JOBID} "$./out/" 2>/dev/null
fi

echo -e "\nnumtasks=$numtasks, numnodes=$numnodes, mpi_tasks_per_node=$mpi_tasks_per_node (OMP_NUM_THREADS=$OMP_NUM_THREADS)"

run_convert $cfg1 

ulimit -s unlimited  # Makes ulimit limit unlimited?
run_nrqcd_parallel $cfg1
wait

cleanup $cfg1

echo "Time: `date`"
