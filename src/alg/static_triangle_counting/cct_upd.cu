#include <cuda.h>
#include <cuda_runtime.h>
#include <stdio.h>
#include <inttypes.h>

#include <thrust/device_ptr.h>
#include <thrust/sort.h>

#include "cct.hpp"
#include "utils.hpp"

// #include "kernel_mergesort.hxx"

__device__ void conditionalWarpReduce(volatile triangle_t* sharedData,int blockSize,int dataLength){
  if(blockSize >= dataLength){
    if(threadIdx.x < (dataLength/2))
    {sharedData[threadIdx.x] += sharedData[threadIdx.x+(dataLength/2)];}
    __syncthreads();
  }
}

__device__ void warpReduce(triangle_t* __restrict__ outDataPtr,
    volatile triangle_t* __restrict__ sharedData,int blockSize){
  conditionalWarpReduce(sharedData,blockSize,64);
  conditionalWarpReduce(sharedData,blockSize,32);
  conditionalWarpReduce(sharedData,blockSize,16);
  conditionalWarpReduce(sharedData,blockSize,8);
  conditionalWarpReduce(sharedData,blockSize,4);
  if(threadIdx.x == 0)
    {*outDataPtr= sharedData[0] + sharedData[1];}
  __syncthreads();
}

__device__ void conditionalReduce(volatile triangle_t* __restrict__ sharedData,int blockSize,int dataLength){
	if(blockSize >= dataLength){
		if(threadIdx.x < (dataLength/2))
		{sharedData[threadIdx.x] += sharedData[threadIdx.x+(dataLength/2)];}
		__syncthreads();
	}
	if((blockSize < dataLength) && (blockSize > (dataLength/2))){
		if(threadIdx.x+(dataLength/2) < blockSize){
			sharedData[threadIdx.x] += sharedData[threadIdx.x+(dataLength/2)];
		}
		__syncthreads();
	}
}

__device__ void blockReduce(triangle_t* __restrict__ outGlobalDataPtr,
    volatile triangle_t* __restrict__ sharedData,int blockSize){
  __syncthreads();
  conditionalReduce(sharedData,blockSize,1024);
  conditionalReduce(sharedData,blockSize,512);
  conditionalReduce(sharedData,blockSize,256);
  conditionalReduce(sharedData,blockSize,128);

  warpReduce(outGlobalDataPtr, sharedData, blockSize);
  __syncthreads();
}

__device__ void initialize(const vertexId_t diag_id, const length_t u_len, length_t v_len,
    length_t* const __restrict__ u_min, length_t* const __restrict__ u_max,
    length_t* const __restrict__ v_min, length_t* const __restrict__ v_max,
    int* const __restrict__ found)
{
	if (diag_id == 0){
		*u_min=*u_max=*v_min=*v_max=0;
		*found=1;
	}
	else if (diag_id < u_len){
		*u_min=0; *u_max=diag_id;
		*v_max=diag_id;*v_min=0;
	}
	else if (diag_id < v_len){
		*u_min=0; *u_max=u_len;
		*v_max=diag_id;*v_min=diag_id-u_len;
	}
	else{
		*u_min=diag_id-v_len; *u_max=u_len;
		*v_min=diag_id-u_len; *v_max=v_len;
	}
}

__device__ void workPerThread(const length_t uLength, const length_t vLength, 
	const int threadsPerIntersection, const int threadId,
    int * const __restrict__ outWorkPerThread, int * const __restrict__ outDiagonalId){
  int totalWork = uLength + vLength;
  int remainderWork = totalWork%threadsPerIntersection;
  int workPerThread = totalWork/threadsPerIntersection;

  int longDiagonals  = (threadId > remainderWork) ? remainderWork:threadId;
  int shortDiagonals = (threadId > remainderWork) ? (threadId - remainderWork):0;

  *outDiagonalId = ((workPerThread+1)*longDiagonals) + (workPerThread*shortDiagonals);
  *outWorkPerThread = workPerThread + (threadId < remainderWork);
}

__device__ void bSearch(unsigned int found, const vertexId_t diagonalId,
    vertexId_t const * const __restrict__ uNodes, vertexId_t const * const __restrict__ vNodes,
    length_t const * const __restrict__ uLength, 
    length_t * const __restrict__ outUMin, length_t * const __restrict__ outUMax,
    length_t * const __restrict__ outVMin, length_t * const __restrict__ outVMax,    
    length_t * const __restrict__ outUCurr,
    length_t * const __restrict__ outVCurr){
  	length_t length;
	
	while(!found) {
	    *outUCurr = (*outUMin + *outUMax)>>1;
	    *outVCurr = diagonalId - *outUCurr;
	    if(*outVCurr >= *outVMax){
			length = *outUMax - *outUMin;
			if(length == 1){
				found = 1;
				continue;
			}
	    }

	    unsigned int comp1 = uNodes[*outUCurr] > vNodes[*outVCurr-1];
	    unsigned int comp2 = uNodes[*outUCurr-1] > vNodes[*outVCurr];
	    if(comp1 && !comp2){
			found = 1;
	    }
	    else if(comp1){
	      *outVMin = *outVCurr;
	      *outUMax = *outUCurr;
	    }
	    else{
	      *outVMax = *outVCurr;
	      *outUMin = *outUCurr;
	    }
  	}

	if((*outVCurr >= *outVMax) && (length == 1) && (*outVCurr > 0) &&
	(*outUCurr > 0) && (*outUCurr < (*uLength - 1))){
		unsigned int comp1 = uNodes[*outUCurr] > vNodes[*outVCurr - 1];
		unsigned int comp2 = uNodes[*outUCurr - 1] > vNodes[*outVCurr];
		if(!comp1 && !comp2){(*outUCurr)++; (*outVCurr)--;}
	}
}

__device__ int fixStartPoint(const length_t uLength, const length_t vLength,
    length_t * const __restrict__ uCurr, length_t * const __restrict__ vCurr,
    vertexId_t const * const __restrict__ uNodes, vertexId_t const * const __restrict__ vNodes){
	
	unsigned int uBigger = (*uCurr > 0) && (*vCurr < vLength) && (uNodes[*uCurr-1] == vNodes[*vCurr]);
	unsigned int vBigger = (*vCurr > 0) && (*uCurr < uLength) && (vNodes[*vCurr-1] == uNodes[*uCurr]);
	*uCurr += vBigger;
	*vCurr += uBigger;
	return (uBigger + vBigger);
}

__device__ void intersectCount(const length_t uLength, const length_t vLength,
    vertexId_t const * const __restrict__ uNodes, vertexId_t const * const __restrict__ vNodes,
    length_t * const __restrict__ uCurr, length_t * const __restrict__ vCurr,
    int * const __restrict__ workIndex, int * const __restrict__ workPerThread,
    int * const __restrict__ triangles, int found)
{
  if((*uCurr < uLength) && (*vCurr < vLength)){
    int comp;
    while(*workIndex < *workPerThread){
		comp = uNodes[*uCurr] - vNodes[*vCurr];
		*triangles += (comp == 0);
		*uCurr += (comp <= 0);
		*vCurr += (comp >= 0);
		*workIndex += (comp == 0) + 1;

		if((*vCurr == vLength) || (*uCurr == uLength)){
			break;
		}
    }
    *triangles -= ((comp == 0) && (*workIndex > *workPerThread) && (found));
  }
}


// u_len < v_len
__device__ triangle_t count_triangles(vertexId_t u, vertexId_t const * const __restrict__ u_nodes, length_t u_len,
    vertexId_t v, vertexId_t const * const __restrict__ v_nodes, length_t v_len, int threads_per_block,
    volatile vertexId_t* __restrict__ firstFound, int tId)
{
	// Partitioning the work to the multiple thread of a single GPU processor. The threads should get a near equal number of the elements to Tersect - this number will be off by 1.
	int work_per_thread, diag_id;
	workPerThread(u_len, v_len, threads_per_block, tId, &work_per_thread, &diag_id);
	triangle_t triangles = 0;
	int work_index = 0,found=0;
	length_t u_min,u_max,v_min,v_max,u_curr,v_curr;

	firstFound[tId]=0;

	if(work_per_thread>0){
		// For the binary search, we are figuring out the initial poT of search.
		initialize(diag_id, u_len, v_len,&u_min, &u_max,&v_min, &v_max,&found);
    	u_curr = 0; v_curr = 0;

	    bSearch(found, diag_id, u_nodes, v_nodes, &u_len, &u_min, &u_max, &v_min,
        &v_max, &u_curr, &v_curr);

    	int sum = fixStartPoint(u_len, v_len, &u_curr, &v_curr, u_nodes, v_nodes);
    	work_index += sum;
	    if(tId > 0)
	      firstFound[tId-1] = sum;
	    triangles += sum;
	    intersectCount(u_len, v_len, u_nodes, v_nodes, &u_curr, &v_curr,
	        &work_index, &work_per_thread, &triangles, firstFound[tId]);
	}
	return triangles;
}

__device__ void intersectCount_nc(const length_t uLength, const length_t vLength,
    vertexId_t const * const __restrict__ uNodes, vertexId_t const * const __restrict__ vNodes,
    length_t * const __restrict__ uCurr, length_t * const __restrict__ vCurr,
    int * const __restrict__ workIndex, int * const __restrict__ workPerThread,
    int * const __restrict__ triangles, int found, triangle_t * const __restrict__ outPutTriangles)
{
  if((*uCurr < uLength) && (*vCurr < vLength)){
    int comp;
    while(*workIndex < *workPerThread){
		comp = uNodes[*uCurr] - vNodes[*vCurr];
		*triangles += (comp == 0);
		if (comp == 0) atomicAdd(outPutTriangles + uNodes[*uCurr], 1);
		*uCurr += (comp <= 0);
		*vCurr += (comp >= 0);
		*workIndex += (comp == 0) + 1;

		if((*vCurr == vLength) || (*uCurr == uLength)){
			break;
		}
    }
    *triangles -= ((comp == 0) && (*workIndex > *workPerThread) && (found));
  }
}


// u_len < v_len
__device__ triangle_t count_triangles_nc(vertexId_t u, vertexId_t const * const __restrict__ u_nodes, length_t u_len,
    vertexId_t v, vertexId_t const * const __restrict__ v_nodes, length_t v_len, int threads_per_block,
    volatile vertexId_t* __restrict__ firstFound, int tId, triangle_t * const __restrict__ outPutTriangles)
{
	// Partitioning the work to the multiple thread of a single GPU processor. The threads should get a near equal number of the elements to Tersect - this number will be off by 1.
	int work_per_thread, diag_id;
	workPerThread(u_len, v_len, threads_per_block, tId, &work_per_thread, &diag_id);
	triangle_t triangles = 0;
	int work_index = 0,found=0;
	length_t u_min,u_max,v_min,v_max,u_curr,v_curr;

	firstFound[tId]=0;

	if(work_per_thread>0){
		// For the binary search, we are figuring out the initial poT of search.
		initialize(diag_id, u_len, v_len,&u_min, &u_max,&v_min, &v_max,&found);
    	u_curr = 0; v_curr = 0;

	    bSearch(found, diag_id, u_nodes, v_nodes, &u_len, &u_min, &u_max, &v_min,
        &v_max, &u_curr, &v_curr);

    	int sum = fixStartPoint(u_len, v_len, &u_curr, &v_curr, u_nodes, v_nodes);
    	work_index += sum;
	    if(tId > 0)
	      firstFound[tId-1] = sum;
	    triangles += sum;
	    intersectCount_nc(u_len, v_len, u_nodes, v_nodes, &u_curr, &v_curr,
	        &work_index, &work_per_thread, &triangles, firstFound[tId], outPutTriangles);
	}
	return triangles;
}

__device__ void workPerBlock(const length_t numVertices,
    length_t * const __restrict__ outMpStart,
    length_t * const __restrict__ outMpEnd, int blockSize)
{
	length_t verticesPerMp = numVertices/gridDim.x;
	length_t remainderBlocks = numVertices % gridDim.x;
	length_t extraVertexBlocks = (blockIdx.x > remainderBlocks)? remainderBlocks:blockIdx.x;
	length_t regularVertexBlocks = (blockIdx.x > remainderBlocks)? blockIdx.x - remainderBlocks:0;

	length_t mpStart = ((verticesPerMp+1)*extraVertexBlocks) + (verticesPerMp*regularVertexBlocks);
	*outMpStart = mpStart;
	*outMpEnd = mpStart + verticesPerMp + (blockIdx.x < remainderBlocks);
}


__global__ void devicecuStingerNewTriangles(cuStinger* custing, BatchUpdateData *bud,
    triangle_t * const __restrict__ outPutTriangles, const int threads_per_block,
    const int number_blocks, const int shifter)
{
	length_t batchSize = *(bud->getBatchSize());
	// Partitioning the work to the multiple thread of a single GPU processor. The threads should get a near equal number of the elements to intersect - this number will be off by no more than one.
	int tx = threadIdx.x;
 	length_t this_mp_start, this_mp_stop;

	const int blockSize = blockDim.x;
	workPerBlock(batchSize, &this_mp_start, &this_mp_stop, blockSize);

	__shared__ vertexId_t firstFound[1024];

	length_t adj_offset=tx>>shifter;
	length_t* firstFoundPos=firstFound + (adj_offset<<shifter);
	for (length_t edge = this_mp_start+adj_offset; edge < this_mp_stop; edge+=number_blocks){
		vertexId_t src = bud->getSrc()[edge];
		vertexId_t dest= bud->getDst()[edge];
		length_t srcLen=custing->dVD->getUsed()[src];
		length_t destLen=custing->dVD->getUsed()[dest];

		bool avoidCalc = (src == dest) || (destLen < 2) || (srcLen < 2);
		if(avoidCalc)
			continue;

		bool sourceSmaller = (srcLen<destLen);
        vertexId_t small = sourceSmaller? src : dest;
        vertexId_t large = sourceSmaller? dest : src;
        length_t small_len = sourceSmaller? srcLen : destLen;
        length_t large_len = sourceSmaller? destLen : srcLen;

        const vertexId_t* small_ptr = custing->dVD->getAdj()[small]->dst;
        const vertexId_t* large_ptr = custing->dVD->getAdj()[large]->dst;

		triangle_t tCount = count_triangles_nc(small, small_ptr, small_len,
								large,large_ptr, large_len,
								threads_per_block,firstFoundPos,
								tx%threads_per_block, outPutTriangles);

		atomicAdd(outPutTriangles + src, tCount);
		atomicAdd(outPutTriangles + dest, tCount);
		__syncthreads();
	}
}

template <typename T>
T sumTriangleArrayTEST(T* h_triangles, vertexId_t nv){	
	T sum=0;
	for(vertexId_t sd=0; sd<(nv);sd++){
	  sum+=h_triangles[sd];
	}
	return sum;
}

__global__ void deviceBUThreeTriangles (const length_t batchsize,
    length_t const * const __restrict__ d_off, vertexId_t const * const __restrict__ d_ind,
    vertexId_t const * const __restrict__ d_seg,
    triangle_t * const __restrict__ outPutTriangles, const int threads_per_block,
    const int number_blocks, const int shifter)
{
	// Partitioning the work to the multiple thread of a single GPU processor. The threads should get a near equal number of the elements to intersect - this number will be off by no more than one.
	int tx = threadIdx.x;
 	length_t this_mp_start, this_mp_stop;

	const int blockSize = blockDim.x;
	workPerBlock(batchsize, &this_mp_start, &this_mp_stop, blockSize);

	__shared__ vertexId_t firstFound[1024];

	length_t adj_offset=tx>>shifter;
	length_t* firstFoundPos=firstFound + (adj_offset<<shifter);
	for (length_t edge = this_mp_start+adj_offset; edge < this_mp_stop; edge+=number_blocks){
		vertexId_t src = d_seg[edge];
		vertexId_t dest= d_ind[edge];
		length_t srcLen= d_off[src+1] - d_off[src];
		length_t destLen=d_off[dest+1] - d_off[dest];

		bool avoidCalc = (src == dest) || (destLen < 2) || (srcLen < 2);
		if(avoidCalc)
			continue;

		bool sourceSmaller = (srcLen<destLen);
        vertexId_t small = sourceSmaller? src : dest;
        vertexId_t large = sourceSmaller? dest : src;
        length_t small_len = sourceSmaller? srcLen : destLen;
        length_t large_len = sourceSmaller? destLen : srcLen;

        vertexId_t const * const small_ptr = d_ind + d_off[small];
        vertexId_t const * const large_ptr = d_ind + d_off[large];

		triangle_t tCount = count_triangles(small, small_ptr, small_len,
								large,large_ptr, large_len,
								threads_per_block,firstFoundPos,
								tx%threads_per_block);

		atomicAdd(outPutTriangles + src, tCount);
		__syncthreads();
	}
}

__global__ void deviceBUTwoCUOneTriangles (cuStinger* custing, const length_t batchsize,
    length_t const * const __restrict__ d_off, vertexId_t const * const __restrict__ d_ind,
    vertexId_t const * const __restrict__ d_seg,
    triangle_t * const __restrict__ outPutTriangles, const int threads_per_block,
    const int number_blocks, const int shifter)
{
	// Partitioning the work to the multiple thread of a single GPU processor. The threads should get a near equal number of the elements to intersect - this number will be off by no more than one.
	int tx = threadIdx.x;
 	vertexId_t this_mp_start, this_mp_stop;

	const int blockSize = blockDim.x;
	workPerBlock(batchsize, &this_mp_start, &this_mp_stop, blockSize);

	__shared__ vertexId_t firstFound[1024];

	length_t adj_offset=tx>>shifter;
	length_t* firstFoundPos=firstFound + (adj_offset<<shifter);
	for (length_t edge = this_mp_start+adj_offset; edge < this_mp_stop; edge+=number_blocks){
		vertexId_t src = d_seg[edge];
		vertexId_t dest= d_ind[edge];
		length_t srcLen= d_off[src+1] - d_off[src];
		length_t destLen=custing->dVD->getUsed()[dest];

		bool avoidCalc = (src == dest) || (destLen < 2) || (srcLen < 2);
		if(avoidCalc)
			continue;

        vertexId_t const * const src_ptr = d_ind + d_off[src];
        vertexId_t const * const dst_ptr = custing->dVD->getAdj()[dest]->dst;

		bool sourceSmaller = (srcLen<destLen);
        vertexId_t small = sourceSmaller? src : dest;
        vertexId_t large = sourceSmaller? dest : src;
        length_t small_len = sourceSmaller? srcLen : destLen;
        length_t large_len = sourceSmaller? destLen : srcLen;

        vertexId_t const * const small_ptr = sourceSmaller? src_ptr : dst_ptr;
        vertexId_t const * const large_ptr = sourceSmaller? dst_ptr : src_ptr;

		triangle_t tCount = count_triangles_nc(small, small_ptr, small_len,
								large,large_ptr, large_len,
								threads_per_block,firstFoundPos,
								tx%threads_per_block, outPutTriangles);

		atomicAdd(outPutTriangles + src, tCount);
		atomicAdd(outPutTriangles + dest, tCount);
		__syncthreads();
	}
}


__global__ void calcEdgelistLengths(BatchUpdateData *bud, length_t* const __restrict__ ell){
	int tid = blockIdx.x * blockDim.x + threadIdx.x;
	length_t batchSize = *(bud->getBatchSize());
	if (tid < batchSize) {
		vertexId_t src = bud->getSrc()[tid];
		atomicAdd(ell+src, 1);
	}
}

__global__ void copyIndices(BatchUpdateData *bud, vertexId_t* const __restrict__ ind,
	vertexId_t* const __restrict__ seg,	length_t* const __restrict__ off,
	length_t* const __restrict__ ell){
	int tid = blockIdx.x * blockDim.x + threadIdx.x;
	length_t batchSize = *(bud->getBatchSize());
	if (tid < batchSize)
	{
		vertexId_t src = bud->getSrc()[tid];
		// Start filling up from the end of the edge list like so:
		// ind = ...___|_,_,_,_,_,_,_,3,8,6|_,_,_,_...
		//                el_mark = ^
		length_t el_mark = atomicSub(ell + src, 1) - 1;
		ind[off[src]+el_mark] = bud->getDst()[tid];
		seg[off[src]+el_mark] = src;
	}
}

template <typename T>
__global__ void initDeviceArray(T* mem, int32_t size, T value)
{
	int32_t idx = blockIdx.x * blockDim.x + threadIdx.x;
	if (idx < size)
	{
		mem[idx] = value;
	}
}

void callDeviceNewTriangles(cuStinger& custing, BatchUpdate& bu, 
    triangle_t * const __restrict__ outPutTriangles, const int threads_per_block,
    const int number_blocks, const int shifter, const int thread_blocks, const int blockdim,
    triangle_t * const __restrict__ h_triangles, triangle_t * const __restrict__ h_triangles_t){

	cudaEvent_t ce_start,ce_stop;

	dim3 numBlocks(1, 1);

	length_t batchsize = *(bu.getHostBUD()->getBatchSize());

	// Calculate all new traingles regardless of repetition
	numBlocks.x = ceil((float)(batchsize*threads_per_block)/(float)blockdim);
	start_clock(ce_start, ce_stop);
	devicecuStingerNewTriangles<<<numBlocks, blockdim>>>(custing.devicePtr(), bu.getDeviceBUD()->devicePtr(), outPutTriangles, threads_per_block,number_blocks,shifter);
	printf("\n%s <%d> %f\n", __FUNCTION__, __LINE__, end_clock(ce_start, ce_stop));

	// Convert BUD to CSR
	// ==================
	length_t nv = custing.nv;

	// Allocate bud offset array and edgelist length
	length_t* d_boff = (length_t*) allocDeviceArray(nv+1, sizeof(length_t));
	length_t* d_ell = (length_t*) allocDeviceArray(nv+1, sizeof(length_t));

	// Calculate edgelist lengths
	numBlocks.x = ceil((float)nv/(float)blockdim);
	start_clock(ce_start, ce_stop);
	initDeviceArray<<<numBlocks,blockdim>>>(d_ell, nv, 0);
	printf("\n%s <%d> %f\n", __FUNCTION__, __LINE__, end_clock(ce_start, ce_stop));

	numBlocks.x = ceil((float)batchsize/(float)blockdim);
	start_clock(ce_start, ce_stop);
	calcEdgelistLengths<<<numBlocks,blockdim>>>(bu.getDeviceBUD()->devicePtr(), d_ell);
	printf("\n%s <%d> %f\n", __FUNCTION__, __LINE__, end_clock(ce_start, ce_stop));

	_DEBUG(
		vertexId_t* h_ell = (vertexId_t*) allocHostArray(nv+1, sizeof(vertexId_t));///
		copyArrayDeviceToHost(d_ell, h_ell, nv+1, sizeof(vertexId_t));///
		int64_t sumupd = sumTriangleArrayTEST(h_ell,nv);///
	)

	// Calculate offsets by exclusive scan
	start_clock(ce_start, ce_stop);
	thrust::device_ptr<vertexId_t> dp_ell(d_ell);
	thrust::device_ptr<vertexId_t> dp_boff(d_boff);
	thrust::exclusive_scan(dp_ell, dp_ell+nv+1, dp_boff);
	printf("\n%s <%d> %f\n", __FUNCTION__, __LINE__, end_clock(ce_start, ce_stop));

	// Make indices array and segment array
	_DEBUG(
		length_t* h_boff = (length_t*) allocHostArray(nv+1, sizeof(length_t));///
		copyArrayDeviceToHost(d_boff, h_boff, nv+1, sizeof(length_t));///
	)
	vertexId_t* d_bind = (vertexId_t*) allocDeviceArray(batchsize, sizeof(vertexId_t));
	vertexId_t* d_bseg = (vertexId_t*) allocDeviceArray(batchsize, sizeof(vertexId_t));

	// Populate indices array and segment array
	start_clock(ce_start, ce_stop);
	copyIndices<<<numBlocks,blockdim>>>(bu.getDeviceBUD()->devicePtr(), d_bind, d_bseg, d_boff, d_ell);
	printf("\n%s <%d> %f\n", __FUNCTION__, __LINE__, end_clock(ce_start, ce_stop));

	// Sort the added edges
	start_clock(ce_start, ce_stop);
	thrust::device_ptr<vertexId_t> dp_bind(d_bind);
	thrust::device_ptr<vertexId_t> dp_bseg(d_bseg);
	thrust::stable_sort_by_key(dp_bind, dp_bind + batchsize, dp_bseg);
	thrust::stable_sort_by_key(dp_bseg, dp_bseg + batchsize, dp_bind);
	printf("\n%s <%d> %f\n", __FUNCTION__, __LINE__, end_clock(ce_start, ce_stop));
	_DEBUG(
		vertexId_t* h_bind = (vertexId_t*) allocHostArray(batchsize, sizeof(vertexId_t));///
		vertexId_t* h_bseg = (vertexId_t*) allocHostArray(batchsize, sizeof(vertexId_t));///
		copyArrayDeviceToHost(d_bind, h_bind, batchsize, sizeof(vertexId_t));///
		copyArrayDeviceToHost(d_bseg, h_bseg, batchsize, sizeof(vertexId_t));///
	)
	// ==================
	// Done converting

	// Calculate triangles formed by only new edges
	triangle_t* d_3tri = (triangle_t*) allocDeviceArray(nv, sizeof(triangle_t));
	start_clock(ce_start, ce_stop);
	numBlocks.x = ceil((float)nv/(float)blockdim);
	initDeviceArray<<<numBlocks,blockdim>>>(d_3tri, nv, 0);
	numBlocks.x = ceil((float)(batchsize*threads_per_block)/(float)blockdim);
	printf("\n%s <%d> %f\n", __FUNCTION__, __LINE__, end_clock(ce_start, ce_stop));
	start_clock(ce_start, ce_stop);
	deviceBUThreeTriangles<<<numBlocks,blockdim>>>(batchsize,d_boff, d_bind, d_bseg, d_3tri, threads_per_block,number_blocks,shifter);
	printf("\n%s <%d> %f\n", __FUNCTION__, __LINE__, end_clock(ce_start, ce_stop));
	
	// Calculate triangles formed by two new and one old edges
	triangle_t* d_2tri = (triangle_t*) allocDeviceArray(nv, sizeof(triangle_t));
	numBlocks.x = ceil((float)nv/(float)blockdim);
	initDeviceArray<<<numBlocks,blockdim>>>(d_2tri, nv, 0);
	start_clock(ce_start, ce_stop);
	numBlocks.x = ceil((float)(batchsize*threads_per_block)/(float)blockdim);
	deviceBUTwoCUOneTriangles<<<numBlocks,blockdim>>>(custing.devicePtr(),batchsize,d_boff, d_bind, d_bseg, d_2tri, threads_per_block,number_blocks,shifter);
	printf("\n%s <%d> %f\n", __FUNCTION__, __LINE__, end_clock(ce_start, ce_stop));

	// TESTING. Remove after done
	triangle_t* h_3tri = (triangle_t*) allocHostArray(nv, sizeof(triangle_t));
	triangle_t* h_2tri = (triangle_t*) allocHostArray(nv, sizeof(triangle_t));
	triangle_t* h_1tri = (triangle_t*) allocHostArray(nv, sizeof(triangle_t));
	cudaMemcpy(h_3tri, d_3tri, sizeof(triangle_t)*nv, cudaMemcpyDeviceToHost);
	cudaMemcpy(h_2tri, d_2tri, sizeof(triangle_t)*nv, cudaMemcpyDeviceToHost);
	cudaMemcpy(h_1tri, outPutTriangles, sizeof(triangle_t)*nv, cudaMemcpyDeviceToHost);
	int64_t sum3 = sumTriangleArrayTEST(h_3tri,nv);
	int64_t sum2 = sumTriangleArrayTEST(h_2tri,nv);
	int64_t sum1 = sumTriangleArrayTEST(h_1tri,nv);

	// Testing
		for (int i = 0; i < nv; ++i)
		{
			if (h_triangles[i] != h_triangles_t[i] + h_1tri[i] - h_2tri[i] + h_3tri[i]){
				printf("wrong vertex set %d + %d instead of %d\n", h_triangles_t[i], h_1tri[i] - h_2tri[i] + h_3tri[i], h_triangles[i]);
				return;
			}
		}

	printf("Sum1=%d \nSum2=%d \n Sum3=%d\n",sum1,sum2,sum3);
	printf("============ new tri = %d\n", (sum1/2 - sum2/2 + sum3/6)*2);
}

