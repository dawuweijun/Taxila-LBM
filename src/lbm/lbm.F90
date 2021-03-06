!!!==================================================================
!!! Fortran-file
!!!    author:        Ethan T. Coon
!!!    filename:      lbregion.f
!!!    version:
!!!    created:       17 November 2010
!!!      on:          12:29:33 MST
!!!    last modified:  17 November 2010
!!!      at:          12:29:33 MST
!!!    URL:           http://www.ldeo.columbia.edu/~ecoon/
!!!    email:         ecoon _at_ ldeo.columbia.edu
!!!
!!!==================================================================
  ! module for region on which LBM will be used
#define PETSC_USE_FORTRAN_MODULES 1
#include "finclude/petscsysdef.h"
#include "finclude/petscvecdef.h"
#include "finclude/petscdmdef.h"

  module LBM_module
    use petsc
    use Timing_module
    use LBM_Error_module
    use LBM_Discretization_module
    use LBM_Grid_module
    use LBM_Distribution_Function_module
    use LBM_Walls_module
    use LBM_Flow_module
    use LBM_Transport_module
    use LBM_IO_module
    use LBM_Options_module
    use LBM_BC_module
    use LBM_Logging_module
    implicit none

    private

#include "lbm_definitions.h"
    type, public:: lbm_type
       MPI_Comm comm
       type(options_type),pointer :: options
       type(grid_type),pointer :: grid
       type(walls_type), pointer :: walls
       type(flow_type),pointer :: flow
       type(transport_type),pointer :: transport
       type(io_type),pointer :: io

       character(len=MAXWORDLENGTH) name
    end type lbm_type

    interface LBMInitializeState
       module procedure LBMInitializeState_Flow
       module procedure LBMInitializeState_FlowTransport
    end interface

    interface LBMInit
       module procedure LBMInit1
       module procedure LBMInit2
    end interface

    interface LBMRun
       module procedure LBMRun1
       module procedure LBMRun2
    end interface

    public :: LBMCreate, &
         LBMDestroy, &
         LBMSetName, &
         LBMSetFromOptions, &
         LBMSetUp, &
         LBMInit, &
         LBMRun, &
         LBMOutput, &
         LBMInitializeState, &
         LBMInitializeStateRestarted, &
         LBMInitializeStateFromFile, &
         LBMLoadSteadyStateFlow, &
         LBMGetCorners

  contains
    function LBMCreate(comm) result(lbm)
      type(lbm_type),pointer:: lbm
      MPI_Comm comm

      allocate(lbm)
      lbm%comm = comm

      lbm%options => OptionsCreate(comm)
      lbm%grid => GridCreate(comm)
      lbm%io => IOCreate(comm)
      lbm%walls => WallsCreate(lbm%comm)
      lbm%flow => FlowCreate(lbm%comm)
      nullify(lbm%transport)

      lbm%name = ''
    end function LBMCreate

    ! --- destroy things
    subroutine LBMDestroy(lbm, ierr)
      type(lbm_type) lbm
      PetscErrorCode ierr

      if (associated(lbm%flow)) call FlowDestroy(lbm%flow,ierr)
      if (associated(lbm%transport)) call TransportDestroy(lbm%transport,ierr)
      call GridDestroy(lbm%grid, ierr)
      call IODestroy(lbm%io, ierr)
      if (associated(lbm%options%waypoints)) deallocate(lbm%options%waypoints)
      return
    end subroutine LBMDestroy

    subroutine LBMSetName(lbm, name)
      type(lbm_type) lbm
      character(len=MAXWORDLENGTH):: name
      lbm%name = name
    end subroutine LBMSetName

    subroutine LBMSetFromOptions(lbm, options, ierr)
      type(lbm_type) lbm
      type(options_type) options
      PetscErrorCode ierr

      call IOSetFromOptions(lbm%io, options, ierr);CHKERRQ(ierr)
      call GridSetFromOptions(lbm%grid, options, ierr);CHKERRQ(ierr)
      call GridSetName(lbm%grid, lbm%name)
      call GridSetPhysicalScales(lbm%grid, ierr);CHKERRQ(ierr)

      call WallsSetGrid(lbm%walls, lbm%grid)
      call WallsSetFromOptions(lbm%walls, options, ierr);CHKERRQ(ierr)

      call FlowSetGrid(lbm%flow, lbm%grid)
      call FlowSetFromOptions(lbm%flow, options, ierr);CHKERRQ(ierr)
      call FlowSetPhysicalScales(lbm%flow,ierr);CHKERRQ(ierr)
      if (options%transport_disc /= NULL_DISCRETIZATION) then
         lbm%transport => TransportCreate(lbm%comm)
         call TransportSetGrid(lbm%transport, lbm%grid)
         call TransportSetFromOptions(lbm%transport, options, ierr);CHKERRQ(ierr)
      end if
    end subroutine LBMSetFromOptions

    subroutine LBMSetUp(lbm)
      type(lbm_type) lbm
      PetscScalar zero
      PetscErrorCode ierr

      zero = 0.d0

      ! set up the DA sizes
      lbm%grid%da_sizes(ONEDOF) = 1
      lbm%grid%da_sizes(NCOMPONENTDOF) = lbm%flow%ncomponents
      lbm%grid%da_sizes(NCOMPONENTXBDOF) = lbm%flow%ncomponents*(lbm%flow%disc%b+1)
      lbm%grid%da_sizes(NFLOWDOF) = lbm%flow%ndims
      if (associated(lbm%transport)) then
         lbm%grid%da_sizes(NSPECIEDOF) = lbm%transport%nspecies
         lbm%grid%da_sizes(NSPECIEXBDOF) = lbm%transport%nspecies*(lbm%transport%disc%b+1)
      end if

      call PetscLogEventBegin(logger%event_init_gridsetup,ierr)
      call GridSetUp(lbm%grid)
      call PetscLogEventEnd(logger%event_init_gridsetup,ierr)

      call PetscLogEventBegin(logger%event_init_wallssetup,ierr)
      call WallsSetUp(lbm%walls)
      call WallsSetValues(lbm%walls, lbm%options)
      call PetscLogEventEnd(logger%event_init_wallssetup,ierr)

      call PetscLogEventBegin(logger%event_init_flowsetup,ierr)
      call FlowSetUp(lbm%flow)
      call PetscLogEventEnd(logger%event_init_flowsetup,ierr)
      if (associated(lbm%transport)) then
         call PetscLogEventBegin(logger%event_init_transetup,ierr)
         call TransportSetUp(lbm%transport)
         call PetscLogEventEnd(logger%event_init_transetup,ierr)
      end if
      return
    end subroutine LBMSetUp

    subroutine LBMInit1(lbm, istep)
      type(lbm_type) lbm
      PetscInt istep
      call LBMInit2(lbm, istep, PETSC_FALSE)
    end subroutine LBMInit1

    subroutine LBMInit2(lbm, istep, supress_output)
      type(lbm_type) lbm
      PetscInt istep
      PetscErrorCode ierr
      PetscBool supress_output

      call WallsCommunicate(lbm%walls)

      if (istep.eq.0) then
         ! get arrays
         call FlowGetArrays(lbm%flow, ierr)
         if (associated(lbm%transport)) then
            call TransportGetArrays(lbm%transport, ierr)
         end if

         ! update values and view
         if ((.not.supress_output).and.(lbm%grid%info%rank.eq.0)) then
            write(*,*) 'outputing step', istep, 'to file', lbm%io%counter
         endif

         ! In the standard initialization approach, moments are provided
         ! and fi is calculated from equilibrium based upon those moments.
         ! flow fi is already initialized in the following cases --
         !  1. we are running a steady state problem and it is pre-calculated
         !  2. we initialized from a restart file
         !  3. we initialized from an IC fi file
         if (((.not.lbm%options%flow_at_steadystate).or. &
              (lbm%options%flow_at_steadystate_rampup_steps > 0)).and. &
              (.not.lbm%options%restart).and.(.not.lbm%options%ic_from_file)) then
           call FlowFiInit(lbm%flow, lbm%walls)
         end if

         if (associated(lbm%transport)) then
           call TransportFiInit(lbm%transport, lbm%walls)
         end if

         if (.not.supress_output) then
           call PetscLogEventBegin(logger%event_output_walls,ierr)
           call WallsOutputDiagnostics(lbm%walls, lbm%io)
           call PetscLogEventEnd(logger%event_output_walls,ierr)
           ! view grid coordinates
!           call PetscLogEventBegin(logger%event_output_grid,ierr)
!           call GridViewCoordinates(lbm%grid, lbm%io)
!           call PetscLogEventEnd(logger%event_output_grid,ierr)
         end if
      else
         ! just get arrays
         call FlowGetArrays(lbm%flow, ierr)
         if (associated(lbm%transport)) then
           call TransportGetArrays(lbm%transport, ierr)
         end if
      endif

      ! hack that needs cleanup and fixing... currently update moments
      ! does not do density, due to wierdness in calculating forces.
      call FlowUpdateMoments(lbm%flow, lbm%walls)
      if (.not.supress_output) then
        call FlowUpdateDiagnostics(lbm%flow, lbm%walls)
        call FlowOutputDiagnostics(lbm%flow, lbm%io)
      end if

      if (associated(lbm%transport)) then
        call TransportUpdateMoments(lbm%transport, lbm%walls)
        call TransportUpdateDiagnostics(lbm%transport, lbm%walls)
        if (.not.supress_output) then
          call TransportOutputDiagnostics(lbm%transport, lbm%io)
        end if
      end if

      call IOIncrementCounter(lbm%io)
    end subroutine LBMInit2

    subroutine LBMRun1(lbm, istep, kstep)
      type(lbm_type) lbm
      PetscInt istep
      PetscInt kstep
      call LBMRun2(lbm, istep, kstep, PETSC_FALSE)
    end subroutine LBMRun1

    subroutine LBMRun2(lbm, istep, kstep, supress_output)
      ! input
      type(lbm_type) lbm
      PetscInt istep
      PetscInt kstep
      PetscBool supress_output

      ! local
      PetscErrorCode ierr
      PetscInt lcv_step
      type(timing_type),pointer:: timer1, timer2, timer3
      character(len=MAXWORDLENGTH) timerunits
      character(len=MAXWORDLENGTH) timername
      PetscScalar norm

      timername = trim(lbm%name)//'Simulation'
      timer1 => TimingCreate(lbm%comm, timername)
      do lcv_step = istep+1,kstep
         ! collision
         call PetscLogStagePop(ierr)
         call PetscLogStagePush(logger%stage(COLLISION_STAGE), ierr)
         if ((.not.lbm%options%flow_at_steadystate).or. &
              (lcv_step < lbm%options%flow_at_steadystate_rampup_steps)) then
            call PetscLogEventBegin(logger%event_collision_flow, ierr)
            call FlowCollision(lbm%flow, lbm%walls)
            call PetscLogEventEnd(logger%event_collision_flow, ierr)
         end if

         if (associated(lbm%transport)) then
            if ((.not.lbm%options%flow_at_steadystate).or. &
                 (lcv_step < lbm%options%flow_at_steadystate_rampup_steps)) then
               call PetscLogEventBegin(logger%event_diagnostics,ierr)
               call FlowUpdateDiagnostics(lbm%flow, lbm%walls)
               call PetscLogEventEnd(logger%event_diagnostics,ierr)
            end if
            call PetscLogEventBegin(logger%event_collision_tran,ierr)
            call TransportCollision(lbm%transport, lbm%walls, lbm%flow)
            call PetscLogEventEnd(logger%event_collision_tran,ierr)
         end if

         ! streaming
         call PetscLogStagePop(ierr)
         call PetscLogStagePush(logger%stage(STREAM_STAGE), ierr)
         if ((.not.lbm%options%flow_at_steadystate).or. &
              (lcv_step < lbm%options%flow_at_steadystate_rampup_steps)) then
            call PetscLogEventBegin(logger%event_communicate_fi, ierr)
            call DistributionCommunicateFi(lbm%flow%distribution)
            call PetscLogEventEnd(logger%event_communicate_fi, ierr)

            call PetscLogEventBegin(logger%event_stream_flow,ierr)
            call FlowStream(lbm%flow)
            call PetscLogEventEnd(logger%event_stream_flow,ierr)
         end if

         if (associated(lbm%transport)) then
            call DistributionCommunicateFi(lbm%transport%distribution)
            call PetscLogEventBegin(logger%event_stream_tran,ierr)
            call TransportStream(lbm%transport)
            call PetscLogEventEnd(logger%event_stream_tran,ierr)
         end if

         call PetscLogStagePop(ierr)
         call PetscLogStagePush(logger%stage(BC_STAGE), ierr)

         ! internal bounceback
         if ((.not.lbm%options%flow_at_steadystate).or. &
              (lcv_step < lbm%options%flow_at_steadystate_rampup_steps)) then
            call PetscLogEventBegin(logger%event_bc_bounceback,ierr)
            call FlowBounceback(lbm%flow, lbm%walls)
            call PetscLogEventEnd(logger%event_bc_bounceback,ierr)
         end if

         if (associated(lbm%transport)) then
            call PetscLogEventBegin(logger%event_bc_tranwallreact,ierr)
            call TransportReactWithWalls(lbm%transport, lbm%walls)
            call PetscLogEventEnd(logger%event_bc_tranwallreact,ierr)
         end if

         ! external boundary conditions
         if ((.not.lbm%options%flow_at_steadystate).or. &
              (lcv_step < lbm%options%flow_at_steadystate_rampup_steps)) then
            call PetscLogEventBegin(logger%event_bc_flow,ierr)
            call FlowApplyBCs(lbm%flow, lbm%walls)
            call PetscLogEventEnd(logger%event_bc_flow,ierr)
         end if

         ! if (associated(lbm%transport)) then
         !    call PetscLogEventBegin(logger%event_bc_tran,ierr)
         !    call TransportApplyBCs(lbm%transport, lbm%walls)
         !    call PetscLogEventEnd(logger%event_bc_tran,ierr)
         ! end if

         ! update moments for rho, psi
         call PetscLogStagePop(ierr)
         call PetscLogStagePush(logger%stage(MOMENTS_STAGE), ierr)
         if ((.not.lbm%options%flow_at_steadystate).or. &
              (lcv_step < lbm%options%flow_at_steadystate_rampup_steps)) then
            call PetscLogEventBegin(logger%event_flow_moments,ierr)
            ! this is bad -- needs to be generalized for all flow methods
            call FlowUpdateFlux(lbm%flow, lbm%walls)
            call PetscLogEventEnd(logger%event_flow_moments,ierr)
         end if

         if (associated(lbm%transport)) then
            call PetscLogEventBegin(logger%event_tran_moments,ierr)
            call TransportUpdateMoments(lbm%transport, lbm%walls)
            call PetscLogEventEnd(logger%event_tran_moments,ierr)
         end if

         ! check for output
         call PetscLogStagePop(ierr)
         call PetscLogStagePush(logger%stage(OUTPUT_STAGE), ierr)
         if (lbm%options%current_waypoint > 0) then
            if (lbm%options%waypoints(lbm%options%current_waypoint) .eq. lcv_step) then
               if (lcv_step.eq.kstep) lbm%flow%io_fi = (lbm%flow%io_fi.OR.lbm%flow%io_last_fi)
               call PetscLogEventBegin(logger%event_output,ierr)
               call LBMOutput(lbm, lcv_step)
               call PetscLogEventEnd(logger%event_output,ierr)
               lbm%options%current_waypoint = lbm%options%current_waypoint + 1
            else if((lbm%options%kwrite > 0).and.(mod(lcv_step,lbm%options%kwrite).eq.0)) then
               if (lcv_step.eq.kstep) lbm%flow%io_fi = (lbm%flow%io_fi.OR.lbm%flow%io_last_fi)
               call PetscLogEventBegin(logger%event_output,ierr)
               call LBMOutput(lbm, lcv_step)
               call PetscLogEventEnd(logger%event_output,ierr)
            endif
         else if((lbm%options%kwrite > 0).and.(mod(lcv_step,lbm%options%kwrite).eq.0)) then
            if (lcv_step.eq.kstep) lbm%flow%io_fi = (lbm%flow%io_fi.OR.lbm%flow%io_last_fi)
            call PetscLogEventBegin(logger%event_output,ierr)
            call LBMOutput(lbm, lcv_step)
            call PetscLogEventEnd(logger%event_output,ierr)
         endif

         ! check for steady-state finished
         if (lbm%options%run_to_steadystate) then
           call DistributionCalcDeltaNorm(lbm%flow%distribution, norm)
           if (norm < lbm%options%steadystate_tolerance .and. lcv_step > istep+2) then
             ! This is the worst instance of ugly fortran-ness in Taxila, I promise!
             if (lbm%grid%info%rank.eq.0) then
               write(*,*) "Exiting steady state solve, norm (tol):", norm, "(", &
                  lbm%options%steadystate_tolerance, ")"
             endif
             exit
           endif
         endif
      end do

      ! if we're solving to steady state, the last timestep may not be a standard i/o check
      if (lbm%options%output_last) then
         call PetscLogStagePop(ierr)
         call PetscLogStagePush(logger%stage(OUTPUT_STAGE), ierr)
         lbm%flow%io_fi = (lbm%flow%io_fi.OR.lbm%flow%io_last_fi)
         call PetscLogEventBegin(logger%event_output,ierr)
         call LBMOutput(lbm, lcv_step)
         call PetscLogEventEnd(logger%event_output,ierr)
      endif

      timerunits = 'timestep'
      call TimingEndPerUnit(timer1, (kstep-istep+1), timerunits, supress_output)
      call TimingDestroy(timer1)
      return
    end subroutine LBMRun2

    subroutine LBMOutput(lbm, istep)
      type(lbm_type) lbm
      PetscInt istep

      if (lbm%grid%info%rank.eq.0) then
         write(*,*) 'outputing step', istep, 'to file', lbm%io%counter
      endif
      if ((.not.lbm%options%flow_at_steadystate).or. &
           (istep < lbm%options%flow_at_steadystate_rampup_steps)) then
         call FlowUpdateDiagnostics(lbm%flow, lbm%walls)
         call FlowOutputDiagnostics(lbm%flow, lbm%io)
      end if

      if (associated(lbm%transport)) then
         call TransportUpdateDiagnostics(lbm%transport, lbm%walls)
         call TransportOutputDiagnostics(lbm%transport, lbm%io)
      end if
      call IOIncrementCounter(lbm%io)
    end subroutine LBMOutput

    subroutine LBMInitializeState_Flow(lbm, init_subroutine)
      type(lbm_type) lbm
      external :: init_subroutine
      PetscErrorCode ierr

      call FlowGetArrays(lbm%flow, ierr)
      call init_subroutine(lbm%flow%distribution%rho_a, lbm%flow%distribution%flux, &
           lbm%walls%walls_a, lbm%flow%distribution, lbm%flow%components, lbm%options)
      call FlowRestoreArrays(lbm%flow, ierr)
    end subroutine LBMInitializeState_Flow

    subroutine LBMInitializeState_FlowTransport(lbm, flow_subroutine, trans_subroutine)
      type(lbm_type) lbm
      external :: flow_subroutine, trans_subroutine
      PetscErrorCode ierr

      ! flow init
      call FlowGetArrays(lbm%flow, ierr)
      call flow_subroutine(lbm%flow%distribution%rho_a, lbm%flow%distribution%flux, &
           lbm%walls%walls_a, lbm%flow%distribution, lbm%flow%components, lbm%options)
      call FlowRestoreArrays(lbm%flow, ierr)

      ! transport init
      call TransportGetArrays(lbm%transport, ierr)
      call trans_subroutine(lbm%transport%distribution%rho_a, &
           lbm%transport%distribution%flux, lbm%walls%walls_a, &
           lbm%transport%distribution, lbm%transport%species, lbm%options)
      call TransportRestoreArrays(lbm%transport, ierr)
    end subroutine LBMInitializeState_FlowTransport

    ! get the corner coordinates of the domain
    subroutine LBMGetCorners(lbm, corners)
      type(lbm_type) lbm
      PetscScalar,dimension(3,2):: corners

      corners = lbm%grid%info%corners
    end subroutine LBMGetCorners

    subroutine LBMInitializeStateFromFile(lbm)
      use petsc
      type(lbm_type) lbm
      PetscBool flag
      PetscErrorCode ierr

      call OptionsGetString(lbm%options, "-ic_file", "IC for distribution function", &
           lbm%options%ic_file, flag, ierr)
      if (flag) then
        if (lbm%grid%info%rank.eq.0) then
          write(*,*) 'reading initial condition from file', lbm%options%ic_file
        endif
        call IOLoadFile(lbm%io, lbm%flow%distribution%fi_g, lbm%options%ic_file)
        call DMGlobalToLocalBegin(lbm%grid%da(NCOMPONENTXBDOF), lbm%flow%distribution%fi_g, &
             INSERT_VALUES, lbm%flow%distribution%fi, ierr)
        call DMGlobalToLocalEnd(lbm%grid%da(NCOMPONENTXBDOF), lbm%flow%distribution%fi_g, &
             INSERT_VALUES, lbm%flow%distribution%fi, ierr)

      else
        call OptionsGetString(lbm%options, "-ic_file_rho", "IC for rho", &
             lbm%options%ic_file, flag, ierr)
        if (flag) then
          if (lbm%grid%info%rank.eq.0) then
            write(*,*) 'reading initial condition for rho from file', lbm%options%ic_file
          endif
          call IOLoadFile(lbm%io, lbm%flow%distribution%rho_g, lbm%options%ic_file)
          call DMGlobalToLocalBegin(lbm%grid%da(NCOMPONENTDOF), lbm%flow%distribution%rho_g, &
               INSERT_VALUES, lbm%flow%distribution%rho, ierr)
          call DMGlobalToLocalEnd(lbm%grid%da(NCOMPONENTDOF), lbm%flow%distribution%rho_g, &
               INSERT_VALUES, lbm%flow%distribution%rho, ierr)
          ! unset the ic_from_file flag, which is implemented as if fi was initialized
          lbm%options%ic_from_file = PETSC_FALSE
        end if
      end if
      return
    end subroutine LBMInitializeStateFromFile

    subroutine LBMInitializeStateRestarted(lbm, istep, kwrite)
      use petsc
      type(lbm_type) lbm
      PetscInt istep, kwrite
      PetscErrorCode ierr

      if (lbm%options%restart_counter > -1) then
         lbm%io%counter = lbm%options%restart_counter
      else if (kwrite > 0) then
         lbm%io%counter = istep/kwrite
      else
         call LBMError(PETSC_COMM_WORLD, 1, &
              'must set -restart_counter to define which file to restart from', ierr)
      end if

      if (lbm%grid%info%rank.eq.0) then
         write(*,*) 'reading step', istep, 'from file', lbm%io%counter
      endif
      call IOLoad(lbm%io, lbm%flow%distribution%fi_g, 'fi')

      call DMGlobalToLocalBegin(lbm%grid%da(NCOMPONENTXBDOF), lbm%flow%distribution%fi_g, &
           INSERT_VALUES, lbm%flow%distribution%fi, ierr)
      call DMGlobalToLocalEnd(lbm%grid%da(NCOMPONENTXBDOF), lbm%flow%distribution%fi_g, &
           INSERT_VALUES, lbm%flow%distribution%fi, ierr)
      return
    end subroutine LBMInitializeStateRestarted

    subroutine LBMLoadSteadyStateFlow(lbm, filename)
      type(lbm_type) lbm
      character(len=MAXSTRINGLENGTH) filename
      PetscViewer viewer
      PetscErrorCode ierr
      call PetscViewerBinaryOpen(lbm%comm, trim(filename), FILE_MODE_READ, viewer, ierr)
      CHKERRQ(ierr)
      call VecLoad(lbm%flow%velt_g, viewer, ierr)
      CHKERRQ(ierr)
      call PetscViewerDestroy(viewer, ierr)
    end subroutine LBMLoadSteadyStateFlow
  end module LBM_module

