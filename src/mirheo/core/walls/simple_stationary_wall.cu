#include "simple_stationary_wall.h"

#include "common_kernels.h"
#include "stationary_walls/box.h"
#include "stationary_walls/cylinder.h"
#include "stationary_walls/plane.h"
#include "stationary_walls/sdf.h"
#include "stationary_walls/sphere.h"
#include "velocity_field/none.h"

#include <mirheo/core/celllist.h>
#include <mirheo/core/field/utils.h>
#include <mirheo/core/logger.h>
#include <mirheo/core/pvs/packers/objects.h>
#include <mirheo/core/pvs/object_vector.h>
#include <mirheo/core/pvs/particle_vector.h>
#include <mirheo/core/pvs/views/ov.h>
#include <mirheo/core/utils/cuda_common.h>
#include <mirheo/core/utils/kernel_launch.h>
#include <mirheo/core/utils/root_finder.h>

#include <cassert>
#include <cmath>
#include <fstream>
#include <texture_types.h>

enum class QueryMode {
   Query,
   Collect    
};

namespace StationaryWallsKernels {

//===============================================================================================
// Removing kernels
//===============================================================================================

template<typename InsideWallChecker>
__global__ void packRemainingParticles(PVview view, ParticlePackerHandler packer, char *outputBuffer,
                                       int *nRemaining, InsideWallChecker checker, int maxNumParticles)
{
    const real tolerance = 1e-6_r;

    const int srcPid = blockIdx.x * blockDim.x + threadIdx.x;
    if (srcPid >= view.size) return;

    const real3 r = make_real3(view.readPosition(srcPid));
    const real val = checker(r);

    if (val <= -tolerance)
    {
        const int dstPid = atomicAggInc(nRemaining);
        packer.particles.pack(srcPid, dstPid, outputBuffer, maxNumParticles);
    }
}

__global__ void unpackRemainingParticles(const char *inputBuffer, ParticlePackerHandler packer, int nRemaining, int maxNumParticles)
{
    const int srcPid = blockIdx.x * blockDim.x + threadIdx.x;
    if (srcPid >= nRemaining) return;

    const int dstPid = srcPid;
    packer.particles.unpack(srcPid, dstPid, inputBuffer, maxNumParticles);
}

template<typename InsideWallChecker>
__global__ void packRemainingObjects(OVview view, ObjectPackerHandler packer, char *output, int *nRemaining, InsideWallChecker checker, int maxNumObj)
{
    const real tolerance = 1e-6_r;

    // One warp per object
    const int gid = blockIdx.x * blockDim.x + threadIdx.x;
    const int objId  = gid / warpSize;
    const int laneId = gid % warpSize;

    if (objId >= view.nObjects) return;

    bool isRemaining = true;
    for (int i = laneId; i < view.objSize; i += warpSize)
    {
        Particle p(view.readParticle(objId * view.objSize + i));
        
        if (checker(p.r) > -tolerance)
        {
            isRemaining = false;
            break;
        }
    }

    isRemaining = warpAll(isRemaining);
    if (!isRemaining) return;

    int dstObjId;
    if (laneId == 0)
        dstObjId = atomicAdd(nRemaining, 1);
    dstObjId = warpShfl(dstObjId, 0);

    size_t offsetObjData = 0;
    
    for (int pid = laneId; pid < view.objSize; pid += warpSize)
    {
        const int srcPid = objId    * view.objSize + pid;
        const int dstPid = dstObjId * view.objSize + pid;
        offsetObjData = packer.particles.pack(srcPid, dstPid, output, maxNumObj * view.objSize);
    }

    if (laneId == 0) packer.objects.pack(objId, dstObjId, output + offsetObjData, maxNumObj);
}

__global__ void unpackRemainingObjects(const char *from, OVview view, ObjectPackerHandler packer, int maxNumObj)
{
    const int objId = blockIdx.x;
    const int tid = threadIdx.x;

    size_t offsetObjData = 0;
    
    for (int pid = tid; pid < view.objSize; pid += blockDim.x)
    {
        const int dstId = objId*view.objSize + pid;
        const int srcId = objId*view.objSize + pid;
        offsetObjData = packer.particles.unpack(srcId, dstId, from, maxNumObj * view.objSize);
    }

    if (tid == 0) packer.objects.unpack(objId, objId, from + offsetObjData, maxNumObj);
}
//===============================================================================================
// Boundary cells kernels
//===============================================================================================

template<typename InsideWallChecker>
__device__ inline bool isCellOnBoundary(const real maximumTravel, real3 cornerCoo, real3 len, InsideWallChecker checker)
{
    int pos = 0, neg = 0;

    for (int i = 0; i < 2; ++i)
        for (int j = 0; j < 2; ++j)
            for (int k = 0; k < 2; ++k)
            {
                // Value in the cell corner
                const real3 shift = make_real3(i ? len.x : 0.0_r, j ? len.y : 0.0_r, k ? len.z : 0.0_r);
                const real s = checker(cornerCoo + shift);

                if (s >  maximumTravel) pos++;
                if (s < -maximumTravel) neg++;
            }

    return (pos != 8 && neg != 8);
}

template<QueryMode queryMode, typename InsideWallChecker>
__global__ void getBoundaryCells(real maximumTravel, CellListInfo cinfo, int *nBoundaryCells, int *boundaryCells, InsideWallChecker checker)
{
    const int cid = blockIdx.x * blockDim.x + threadIdx.x;
    if (cid >= cinfo.totcells) return;

    int3 ind;
    cinfo.decode(cid, ind.x, ind.y, ind.z);
    real3 cornerCoo = -0.5_r * cinfo.localDomainSize + make_real3(ind)*cinfo.h;

    if (isCellOnBoundary(maximumTravel, cornerCoo, cinfo.h, checker))
    {
        int id = atomicAggInc(nBoundaryCells);
        if (queryMode == QueryMode::Collect)
            boundaryCells[id] = cid;
    }
}

//===============================================================================================
// Checking kernel
//===============================================================================================

template<typename InsideWallChecker>
__global__ void checkInside(PVview view, int *nInside, const InsideWallChecker checker)
{
    const real checkTolerance = 1e-4_r;

    const int pid = blockIdx.x * blockDim.x + threadIdx.x;
    if (pid >= view.size) return;

    Real3_int coo(view.readPosition(pid));

    real v = checker(coo.v);

    if (v > checkTolerance) atomicAggInc(nInside);
}

//===============================================================================================
// Kernels computing sdf and sdf gradient per particle
//===============================================================================================

template<typename InsideWallChecker>
__global__ void computeSdfPerParticle(PVview view, real gradientThreshold, real *sdfs, real3 *gradients, InsideWallChecker checker)
{
    const real h = 0.25_r;
    const real zeroTolerance = 1e-10_r;

    const int pid = blockIdx.x * blockDim.x + threadIdx.x;
    if (pid >= view.size) return;

    Particle p;
    view.readPosition(p, pid);

    real sdf = checker(p.r);
    sdfs[pid] = sdf;

    if (gradients != nullptr && sdf > -gradientThreshold)
    {
        real3 grad = computeGradient(checker, p.r, h);

        if (dot(grad, grad) < zeroTolerance)
            gradients[pid] = make_real3(0, 0, 0);
        else
            gradients[pid] = normalize(grad);
    }
}


template<typename InsideWallChecker>
__global__ void computeSdfPerPosition(int n, const real3 *positions, real *sdfs, InsideWallChecker checker)
{
    int pid = blockIdx.x * blockDim.x + threadIdx.x;
    if (pid >= n) return;
    
    auto r = positions[pid];    

    sdfs[pid] = checker(r);
}

template<typename InsideWallChecker>
__global__ void computeSdfOnGrid(CellListInfo gridInfo, real *sdfs, InsideWallChecker checker)
{
    const int nid = blockIdx.x * blockDim.x + threadIdx.x;
    
    if (nid >= gridInfo.totcells) return;
    
    const int3 cid3 = gridInfo.decode(nid);
    const real3 r = gridInfo.h * make_real3(cid3) + 0.5_r * gridInfo.h - 0.5*gridInfo.localDomainSize;
    
    sdfs[nid] = checker(r);
}

} // namespace StationaryWallsKernels

//===============================================================================================
// Member functions
//===============================================================================================

template<class InsideWallChecker>
SimpleStationaryWall<InsideWallChecker>::SimpleStationaryWall(std::string name, const MirState *state, InsideWallChecker&& insideWallChecker) :
    SDF_basedWall(state, name),
    insideWallChecker(std::move(insideWallChecker))
{
    bounceForce.clear(defaultStream);
}

template<class InsideWallChecker>
SimpleStationaryWall<InsideWallChecker>::~SimpleStationaryWall() = default;

template<class InsideWallChecker>
void SimpleStationaryWall<InsideWallChecker>::setup(MPI_Comm& comm)
{
    info("Setting up wall %s", name.c_str());

    CUDA_Check( cudaDeviceSynchronize() );

    insideWallChecker.setup(comm, state->domain);

    CUDA_Check( cudaDeviceSynchronize() );
}

template<class InsideWallChecker>
void SimpleStationaryWall<InsideWallChecker>::setPrerequisites(ParticleVector *pv)
{
    // do not set it to persistent because bounce happens after integration
    pv->requireDataPerParticle<real4> (ChannelNames::oldPositions, DataManager::PersistenceMode::None, DataManager::ShiftMode::Active);
}

template<class InsideWallChecker>
void SimpleStationaryWall<InsideWallChecker>::attachFrozen(ParticleVector *pv)
{
    frozen = pv;
    info("Wall '%s' will treat particle vector '%s' as frozen", name.c_str(), pv->name.c_str());
}

template<class InsideWallChecker>
void SimpleStationaryWall<InsideWallChecker>::attach(ParticleVector *pv, CellList *cl, real maximumPartTravel)
{
    if (pv == frozen)
    {
        warn("Particle Vector '%s' declared as frozen for the wall '%s'. Bounce-back won't work",
             pv->name.c_str(), name.c_str());
        return;
    }
    
    if (dynamic_cast<PrimaryCellList*>(cl) == nullptr)
        die("PVs should only be attached to walls with the primary cell-lists! "
            "Invalid combination: wall %s, pv %s", name.c_str(), pv->name.c_str());

    CUDA_Check( cudaDeviceSynchronize() );
    particleVectors.push_back(pv);
    cellLists.push_back(cl);

    const int nthreads = 128;
    const int nblocks = getNblocks(cl->totcells, nthreads);
    
    PinnedBuffer<int> nBoundaryCells(1);
    nBoundaryCells.clear(defaultStream);

    SAFE_KERNEL_LAUNCH(
        StationaryWallsKernels::getBoundaryCells<QueryMode::Query>,
        nblocks, nthreads, 0, defaultStream,
        maximumPartTravel, cl->cellInfo(), nBoundaryCells.devPtr(),
        nullptr, insideWallChecker.handler() );

    nBoundaryCells.downloadFromDevice(defaultStream);

    debug("Found %d boundary cells", nBoundaryCells[0]);
    DeviceBuffer<int> bc(nBoundaryCells[0]);

    nBoundaryCells.clear(defaultStream);
    SAFE_KERNEL_LAUNCH(
        StationaryWallsKernels::getBoundaryCells<QueryMode::Collect>,
        nblocks, nthreads, 0, defaultStream,
        maximumPartTravel, cl->cellInfo(), nBoundaryCells.devPtr(),
        bc.devPtr(), insideWallChecker.handler() );

    boundaryCells.push_back(std::move(bc));
    CUDA_Check( cudaDeviceSynchronize() );
}

static bool keepAllpersistentDataPredicate(const DataManager::NamedChannelDesc& namedDesc)
{
    return namedDesc.second->persistence == DataManager::PersistenceMode::Active;
};

template<class InsideWallChecker>
void SimpleStationaryWall<InsideWallChecker>::removeInner(ParticleVector *pv)
{
    if (pv == frozen)
    {
        warn("Particle Vector '%s' declared as frozen for the wall '%s'. Will not remove any particles from there",
             pv->name.c_str(), name.c_str());
        return;
    }
    
    CUDA_Check( cudaDeviceSynchronize() );

    PinnedBuffer<int> nRemaining(1);
    nRemaining.clear(defaultStream);

    const int oldSize = pv->local()->size();
    if (oldSize == 0) return;

    constexpr int nthreads = 128;
    // Need a different path for objects
    if (auto ov = dynamic_cast<ObjectVector*>(pv))
    {
        // Prepare temp storage for extra object data
        OVview ovView(ov, ov->local());
        ObjectPacker packer(keepAllpersistentDataPredicate);
        packer.update(ov->local(), defaultStream);
        const int maxNumObj = ovView.nObjects;

        DeviceBuffer<char> tmp(packer.getSizeBytes(maxNumObj));

        constexpr int warpSize = 32;
        
        SAFE_KERNEL_LAUNCH(
            StationaryWallsKernels::packRemainingObjects,
            getNblocks(ovView.nObjects*warpSize, nthreads), nthreads, 0, defaultStream,
            ovView, packer.handler(), tmp.devPtr(), nRemaining.devPtr(),
            insideWallChecker.handler(), maxNumObj );

        nRemaining.downloadFromDevice(defaultStream);
        
        if (nRemaining[0] != ovView.nObjects)
        {
            info("Removing %d out of %d '%s' objects from walls '%s'",
                 ovView.nObjects - nRemaining[0], ovView.nObjects,
                 ov->name.c_str(), this->name.c_str());

            // Copy temporary buffers back
            ov->local()->resize_anew(nRemaining[0] * ov->objSize);
            ovView = OVview(ov, ov->local());
            packer.update(ov->local(), defaultStream);

            SAFE_KERNEL_LAUNCH(
                StationaryWallsKernels::unpackRemainingObjects,
                ovView.nObjects, nthreads, 0, defaultStream,
                tmp.devPtr(), ovView, packer.handler(), maxNumObj );
        }
    }
    else
    {
        PVview view(pv, pv->local());
        ParticlePacker packer(keepAllpersistentDataPredicate);
        packer.update(pv->local(), defaultStream);
        const int maxNumParticles = view.size;

        DeviceBuffer<char> tmpBuffer(packer.getSizeBytes(maxNumParticles));
        
        SAFE_KERNEL_LAUNCH(
            StationaryWallsKernels::packRemainingParticles,
            getNblocks(view.size, nthreads), nthreads, 0, defaultStream,
            view, packer.handler(), tmpBuffer.devPtr(), nRemaining.devPtr(),
            insideWallChecker.handler(), maxNumParticles );

        nRemaining.downloadFromDevice(defaultStream);
        const int newSize = nRemaining[0];

        if (newSize != oldSize)
        {
            info("Removing %d out of %d '%s' particles from walls '%s'",
                 oldSize - newSize, oldSize,
                 pv->name.c_str(), this->name.c_str());
            
            pv->local()->resize_anew(newSize);
            packer.update(pv->local(), defaultStream);

            SAFE_KERNEL_LAUNCH(
                StationaryWallsKernels::unpackRemainingParticles,
                getNblocks(newSize, nthreads), nthreads, 0, defaultStream,
                tmpBuffer.devPtr(), packer.handler(), newSize, maxNumParticles );
        }
    }

    pv->haloValid   = false;
    pv->redistValid = false;
    pv->cellListStamp++;

    info("Wall '%s' has removed inner entities of pv '%s', keeping %d out of %d particles",
         name.c_str(), pv->name.c_str(), pv->local()->size(), oldSize);

    CUDA_Check( cudaDeviceSynchronize() );
}

template<class InsideWallChecker>
void SimpleStationaryWall<InsideWallChecker>::bounce(cudaStream_t stream)
{
    real dt = this->state->dt;

    bounceForce.clear(stream);
    
    for (size_t i = 0; i < particleVectors.size(); ++i)
    {
        auto  pv = particleVectors[i];
        auto  cl = cellLists[i];
        auto& bc = boundaryCells[i];
        auto  view = cl->getView<PVviewWithOldParticles>();

        debug2("Bouncing %d %s particles, %d boundary cells",
               pv->local()->size(), pv->name.c_str(), bc.size());

        const int nthreads = 64;
        SAFE_KERNEL_LAUNCH(
                BounceKernels::sdfBounce,
                getNblocks(bc.size(), nthreads), nthreads, 0, stream,
                view, cl->cellInfo(),
                bc.devPtr(), bc.size(), dt,
                insideWallChecker.handler(),
                VelocityField_None(),
                bounceForce.devPtr());

        CUDA_Check( cudaPeekAtLastError() );
    }
}

template<class InsideWallChecker>
void SimpleStationaryWall<InsideWallChecker>::check(cudaStream_t stream)
{
    constexpr int nthreads = 128;
    for (auto pv : particleVectors)
    {
        nInside.clearDevice(stream);
        const PVview view(pv, pv->local());

        SAFE_KERNEL_LAUNCH(
            StationaryWallsKernels::checkInside,
            getNblocks(view.size, nthreads), nthreads, 0, stream,
            view, nInside.devPtr(), insideWallChecker.handler() );

        nInside.downloadFromDevice(stream);

        info("%d particles of %s are inside the wall %s", nInside[0], pv->name.c_str(), name.c_str());
    }
}

template<class InsideWallChecker>
void SimpleStationaryWall<InsideWallChecker>::sdfPerParticle(LocalParticleVector* lpv,
        GPUcontainer *sdfs, GPUcontainer* gradients, real gradientThreshold, cudaStream_t stream)
{
    const int nthreads = 128;
    const int np = lpv->size();
    auto pv = lpv->pv;

    if (sizeof(real) % sdfs->datatype_size() != 0)
        die("Incompatible datatype size of container for SDF values: %d (working with PV '%s')",
            sdfs->datatype_size(), pv->name.c_str());
    sdfs->resize_anew( np*sizeof(real) / sdfs->datatype_size());

    
    if (gradients != nullptr)
    {
        if (sizeof(real3) % gradients->datatype_size() != 0)
            die("Incompatible datatype size of container for SDF gradients: %d (working with PV '%s')",
                gradients->datatype_size(), pv->name.c_str());
        gradients->resize_anew( np*sizeof(real3) / gradients->datatype_size());
    }

    PVview view(pv, lpv);
    SAFE_KERNEL_LAUNCH(
        StationaryWallsKernels::computeSdfPerParticle,
        getNblocks(view.size, nthreads), nthreads, 0, stream,
        view, gradientThreshold, (real*)sdfs->genericDevPtr(),
        (gradients != nullptr) ? (real3*)gradients->genericDevPtr() : nullptr, insideWallChecker.handler() );
}


template<class InsideWallChecker>
void SimpleStationaryWall<InsideWallChecker>::sdfPerPosition(GPUcontainer *positions, GPUcontainer* sdfs, cudaStream_t stream)
{
    int n = positions->size();
    
    if (sizeof(real) % sdfs->datatype_size() != 0)
        die("Incompatible datatype size of container for SDF values: %d (sampling sdf on positions)",
            sdfs->datatype_size());

    if (sizeof(real3) % sdfs->datatype_size() != 0)
        die("Incompatible datatype size of container for Psitions values: %d (sampling sdf on positions)",
            positions->datatype_size());
    
    const int nthreads = 128;
    SAFE_KERNEL_LAUNCH(
        StationaryWallsKernels::computeSdfPerPosition,
        getNblocks(n, nthreads), nthreads, 0, stream,
        n, (real3*)positions->genericDevPtr(), (real*)sdfs->genericDevPtr(), insideWallChecker.handler() );
}


template<class InsideWallChecker>
void SimpleStationaryWall<InsideWallChecker>::sdfOnGrid(real3 h, GPUcontainer* sdfs, cudaStream_t stream)
{
    if (sizeof(real) % sdfs->datatype_size() != 0)
        die("Incompatible datatype size of container for SDF values: %d (sampling sdf on a grid)",
            sdfs->datatype_size());
        
    CellListInfo gridInfo(h, state->domain.localSize);
    sdfs->resize_anew(gridInfo.totcells);

    const int nthreads = 128;
    SAFE_KERNEL_LAUNCH(
        StationaryWallsKernels::computeSdfOnGrid,
        getNblocks(gridInfo.totcells, nthreads), nthreads, 0, stream,
        gridInfo, (real*)sdfs->genericDevPtr(), insideWallChecker.handler() );
}

template<class InsideWallChecker>
PinnedBuffer<double3>* SimpleStationaryWall<InsideWallChecker>::getCurrentBounceForce()
{
    return &bounceForce;
}

template class SimpleStationaryWall<StationaryWall_Sphere>;
template class SimpleStationaryWall<StationaryWall_Cylinder>;
template class SimpleStationaryWall<StationaryWall_SDF>;
template class SimpleStationaryWall<StationaryWall_Plane>;
template class SimpleStationaryWall<StationaryWall_Box>;



