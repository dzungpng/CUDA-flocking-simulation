#define GLM_FORCE_CUDA
#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include <glm/glm.hpp>
#include "utilityCore.hpp"
#include "kernel.h"

// LOOK-2.1 potentially useful for doing grid-based neighbor search
#ifndef imax
#define imax( a, b ) ( ((a) > (b)) ? (a) : (b) )
#endif

#ifndef imin
#define imin( a, b ) ( ((a) < (b)) ? (a) : (b) )
#endif

#define checkCUDAErrorWithLine(msg) checkCUDAError(msg, __LINE__)

/**
* Check for CUDA errors; print and exit if there was a problem.
*/
void checkCUDAError(const char* msg, int line = -1) {
	cudaError_t err = cudaGetLastError();
	if (cudaSuccess != err) {
		if (line >= 0) {
			fprintf(stderr, "Line %d: ", line);
		}
		fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString(err));
		exit(EXIT_FAILURE);
	}
}


/*****************
* Configuration *
*****************/

/*! Block size used for CUDA kernel launch. */
#define blockSize 128

// LOOK-1.2 Parameters for the boids algorithm.
// These worked well in our reference implementation.
#define rule1Distance 5.0f
#define rule2Distance 3.0f
#define rule3Distance 5.0f

#define rule1Scale 0.01f
#define rule2Scale 0.1f
#define rule3Scale 0.1f

#define maxSpeed 1.0f

/*! Size of the starting area in simulation space. */
#define scene_scale 100.0f

/***********************************************
* Kernel state (pointers are device pointers) *
***********************************************/

int numObjects;
dim3 threadsPerBlock(blockSize);

// LOOK-1.2 - These buffers are here to hold all your boid information.
// These get allocated for you in Boids::initSimulation.
// Consider why you would need two velocity buffers in a simulation where each
// boid cares about its neighbors' velocities.
// These are called ping-pong buffers.
glm::vec3* dev_pos;
glm::vec3* dev_vel1;
glm::vec3* dev_vel2;

glm::vec3* dev_pos_reordered;

// LOOK-2.1 - these are NOT allocated for you. You'll have to set up the thrust
// pointers on your own too.

// For efficient sorting and the uniform grid. These should always be parallel.
int* dev_particleArrayIndices; // What index in dev_pos and dev_velX represents this particle?
int* dev_particleGridIndices; // What grid cell is this particle in?
// needed for use with thrust
thrust::device_ptr<int> dev_thrust_particleArrayIndices;
thrust::device_ptr<int> dev_thrust_particleGridIndices;

int* dev_gridCellStartIndices; // What part of dev_particleArrayIndices belongs
int* dev_gridCellEndIndices;   // to this cell?

// TODO-2.3 - consider what additional buffers you might need to reshuffle
// the position and velocity data to be coherent within cells.

// LOOK-2.1 - Grid parameters based on simulation parameters.
// These are automatically computed for you in Boids::initSimulation
int gridCellCount;
int gridSideCount;
float gridCellWidth;
float gridInverseCellWidth;
glm::vec3 gridMinimum;
float neighborhoodDistance;

/******************
* initSimulation *
******************/

__host__ __device__ unsigned int hash(unsigned int a) {
	a = (a + 0x7ed55d16) + (a << 12);
	a = (a ^ 0xc761c23c) ^ (a >> 19);
	a = (a + 0x165667b1) + (a << 5);
	a = (a + 0xd3a2646c) ^ (a << 9);
	a = (a + 0xfd7046c5) + (a << 3);
	a = (a ^ 0xb55a4f09) ^ (a >> 16);
	return a;
}

/**
* LOOK-1.2 - this is a typical helper function for a CUDA kernel.
* Function for generating a random vec3.
*/
__host__ __device__ glm::vec3 generateRandomVec3(float time, int index) {
	thrust::default_random_engine rng(hash((int)(index * time)));
	thrust::uniform_real_distribution<float> unitDistrib(-1, 1);

	return glm::vec3((float)unitDistrib(rng), (float)unitDistrib(rng), (float)unitDistrib(rng));
}

/**
* LOOK-1.2 - This is a basic CUDA kernel.
* CUDA kernel for generating boids with a specified mass randomly around the star.
*/
__global__ void kernGenerateRandomPosArray(int time, int N, glm::vec3* arr, float scale) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index < N) {
		glm::vec3 rand = generateRandomVec3(time, index);
		arr[index].x = scale * rand.x;
		arr[index].y = scale * rand.y;
		arr[index].z = scale * rand.z;
	}
}

/**
* Initialize memory, update some globals
*/
void Boids::initSimulation(int N) {
	numObjects = N;
	dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

	// LOOK-1.2 - This is basic CUDA memory management and error checking.
	// Don't forget to cudaFree in  Boids::endSimulation.
	cudaMalloc((void**)&dev_pos, N * sizeof(glm::vec3));
	checkCUDAErrorWithLine("cudaMalloc dev_pos failed!");

	cudaMalloc((void**)&dev_vel1, N * sizeof(glm::vec3));
	checkCUDAErrorWithLine("cudaMalloc dev_vel1 failed!");

	cudaMalloc((void**)&dev_vel2, N * sizeof(glm::vec3));
	checkCUDAErrorWithLine("cudaMalloc dev_vel2 failed!");

	// For part 2.3
	cudaMalloc((void**)&dev_pos_reordered, N * sizeof(glm::vec3));
	checkCUDAErrorWithLine("cudaMalloc dev_pos_reordered failed!");


	// LOOK-1.2 - This is a typical CUDA kernel invocation.
	kernGenerateRandomPosArray << <fullBlocksPerGrid, blockSize >> > (1, numObjects,
		dev_pos, scene_scale);
	checkCUDAErrorWithLine("kernGenerateRandomPosArray failed!");

	// LOOK-2.1 computing grid params
	gridCellWidth = 2.0f * std::max(std::max(rule1Distance, rule2Distance), rule3Distance);
	neighborhoodDistance = gridCellWidth / 2.0f;
	std::cout << "Search radius " <<  neighborhoodDistance << std::endl;
	int halfSideCount = (int)(scene_scale / gridCellWidth) + 1;
	gridSideCount = 2 * halfSideCount;

	gridCellCount = gridSideCount * gridSideCount * gridSideCount;
	gridInverseCellWidth = 1.0f / gridCellWidth;
	float halfGridWidth = gridCellWidth * halfSideCount;
	gridMinimum.x -= halfGridWidth;
	gridMinimum.y -= halfGridWidth;
	gridMinimum.z -= halfGridWidth;

	// TODO-2.1 TODO-2.3 - Allocate additional buffers here.
	cudaMalloc((void**)&dev_particleArrayIndices, N * sizeof(int));
	checkCUDAErrorWithLine("cudaMallock dev_particleArrayIndices failed!");

	cudaMalloc((void**)&dev_particleGridIndices, N * sizeof(int));
	checkCUDAErrorWithLine("cudaMallock dev_particleGridIndices failed!");

	cudaMalloc((void**)&dev_gridCellStartIndices, N * sizeof(int));
	checkCUDAErrorWithLine("cudaMallock dev_gridCellStartIndices failed!");

	cudaMalloc((void**)&dev_gridCellEndIndices, N * sizeof(int));
	checkCUDAErrorWithLine("cudaMallock dev_gridCellEndIndices failed!");

	cudaDeviceSynchronize();
}


/******************
* copyBoidsToVBO *
******************/

/**
* Copy the boid positions into the VBO so that they can be drawn by OpenGL.
*/
__global__ void kernCopyPositionsToVBO(int N, glm::vec3* pos, float* vbo, float s_scale) {
	int index = threadIdx.x + (blockIdx.x * blockDim.x);

	float c_scale = -1.0f / s_scale;

	if (index < N) {
		vbo[4 * index + 0] = pos[index].x * c_scale;
		vbo[4 * index + 1] = pos[index].y * c_scale;
		vbo[4 * index + 2] = pos[index].z * c_scale;
		vbo[4 * index + 3] = 1.0f;
	}
}

__global__ void kernCopyVelocitiesToVBO(int N, glm::vec3* vel, float* vbo, float s_scale) {
	int index = threadIdx.x + (blockIdx.x * blockDim.x);

	if (index < N) {
		vbo[4 * index + 0] = vel[index].x + 0.3f;
		vbo[4 * index + 1] = vel[index].y + 0.3f;
		vbo[4 * index + 2] = vel[index].z + 0.3f;
		vbo[4 * index + 3] = 1.0f;
	}
}

/**
* Wrapper for call to the kernCopyboidsToVBO CUDA kernel.
*/
void Boids::copyBoidsToVBO(float* vbodptr_positions, float* vbodptr_velocities) {
	dim3 fullBlocksPerGrid((numObjects + blockSize - 1) / blockSize);

	kernCopyPositionsToVBO << <fullBlocksPerGrid, blockSize >> > (numObjects, dev_pos, vbodptr_positions, scene_scale);
	kernCopyVelocitiesToVBO << <fullBlocksPerGrid, blockSize >> > (numObjects, dev_vel1, vbodptr_velocities, scene_scale);

	checkCUDAErrorWithLine("copyBoidsToVBO failed!");

	cudaDeviceSynchronize();
}


/******************
* stepSimulation *
******************/


/**
* LOOK-1.2 You can use this as a helper for kernUpdateVelocityBruteForce.
* __device__ code can be called from a __global__ context
* Compute the new velocity on the body with index `iSelf` due to the `N` boids
* in the `pos` and `vel` arrays.
*/
__device__ glm::vec3 computeVelocityChange(int N, int iSelf, const glm::vec3* pos, const glm::vec3* vel) {
	// Variables for rule 1
	glm::vec3 perceivedCenter(0.f, 0.f, 0.f);
	int numNeighbors1 = 0;
	// Variables for rule 2
	glm::vec3 c(0.f, 0.f, 0.f);
	// Variables for rule 3
	glm::vec3 perceivedVelocity(0.f, 0.f, 0.f);
	int numNeighbors3 = 0;
	for (int i = 0; i < N; i++) {
		if (iSelf != i) {
			float distance = glm::distance(pos[iSelf], pos[i]);
			// Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
			if (distance < rule1Distance) {
				perceivedCenter += pos[i];
				numNeighbors1++;
			}
			// Rule 2: boids try to stay a distance d away from each other
			if (distance < rule2Distance) {
				c -= (pos[i] - pos[iSelf]);
			}
			// Rule 3: boids try to match the speed of surrounding boids
			if (distance < rule3Distance) {
				perceivedVelocity += vel[i];
				numNeighbors3++;
			}
		}
	}
	glm::vec3 newVelocity = vel[iSelf];
	// Rule 1 change
	if (numNeighbors1 > 0) {
		perceivedCenter /= numNeighbors1;
		newVelocity += ((perceivedCenter - pos[iSelf]) * rule1Scale);
	}
	// Rule 2 change
	newVelocity += c * rule2Scale;

	// Rule 3 change
	if (numNeighbors3 > 0) {
		perceivedVelocity /= numNeighbors3;
		newVelocity += perceivedVelocity * rule3Scale;
	}
	return newVelocity;
}

/**
* TODO-1.2 implement basic flocking
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdateVelocityBruteForce(int N, glm::vec3* pos,
	glm::vec3* vel1, glm::vec3* vel2) {
	int index = threadIdx.x + blockIdx.x * blockDim.x;
	if (index >= N) {
		return;
	}
	// Compute a new velocity based on pos and vel1
	glm::vec3 newVelocity = computeVelocityChange(N, index, pos, vel1);
	// Clamp the speed
	if (glm::length(newVelocity) > maxSpeed) {
		newVelocity = glm::normalize(newVelocity);
	}
	// Record the new velocity into vel2. Question: why NOT vel1?
	vel2[index] = newVelocity;
}

/**
* LOOK-1.2 Since this is pretty trivial, we implemented it for you.
* For each of the `N` bodies, update its position based on its current velocity.
*/
__global__ void kernUpdatePos(int N, float dt, glm::vec3* pos, glm::vec3* vel) {
	// Update position by velocity
	int index = threadIdx.x + (blockIdx.x * blockDim.x);
	if (index >= N) {
		return;
	}
	glm::vec3 thisPos = pos[index];
	thisPos += vel[index] * dt;

	// Wrap the boids around so we don't lose them
	thisPos.x = thisPos.x < -scene_scale ? scene_scale : thisPos.x;
	thisPos.y = thisPos.y < -scene_scale ? scene_scale : thisPos.y;
	thisPos.z = thisPos.z < -scene_scale ? scene_scale : thisPos.z;

	thisPos.x = thisPos.x > scene_scale ? -scene_scale : thisPos.x;
	thisPos.y = thisPos.y > scene_scale ? -scene_scale : thisPos.y;
	thisPos.z = thisPos.z > scene_scale ? -scene_scale : thisPos.z;

	pos[index] = thisPos;
}

// LOOK-2.1 Consider this method of computing a 1D index from a 3D grid index.
// LOOK-2.3 Looking at this method, what would be the most memory efficient
//          order for iterating over neighboring grid cells?
//          for(x)
//            for(y)
//             for(z)? Or some other order?
__device__ int gridIndex3Dto1D(int x, int y, int z, int gridResolution) {
	return x + y * gridResolution + z * gridResolution * gridResolution;
}

__global__ void kernComputeIndices(int N, int gridResolution,
	glm::vec3 gridMin, float inverseCellWidth,
	glm::vec3* pos, int* indices, int* gridIndices) {
	// TODO-2.1
	// - Label each boid with the index of its grid cell.
	// - Set up a parallel array of integer indices as pointers to the actual
	//   boid data in pos and vel1/vel2
	int boidIndex = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (boidIndex >= N) {
		return;
	}
	int gridIndex = gridIndex3Dto1D(
		floor((pos[boidIndex].x - gridMin.x) * inverseCellWidth),
		floor((pos[boidIndex].y - gridMin.y) * inverseCellWidth),
		floor((pos[boidIndex].z - gridMin.z) * inverseCellWidth),
		gridResolution
	);
	gridIndices[boidIndex] = gridIndex;
	indices[boidIndex] = boidIndex;
}

// LOOK-2.1 Consider how this could be useful for indicating that a cell
//          does not enclose any boids
__global__ void kernResetIntBuffer(int N, int* intBuffer, int value) {
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index < N) {
		intBuffer[index] = value;
	}

}

__global__ void kernIdentifyCellStartEnd(int N, int* particleGridIndices,
	int* gridCellStartIndices, int* gridCellEndIndices) {
	// TODO-2.1
	// Identify the start point of each cell in the gridIndices array.
	// This is basically a parallel unrolling of a loop that goes
	// "this index doesn't match the one before it, must be a new cell!"
	int index = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (index >= N) {
		return;
	}
	if (index == 0) {
		gridCellStartIndices[particleGridIndices[index]] = 0;
	}
	if (index > 0) {
		int currGridIndex = particleGridIndices[index];
		int prevGridIndex = particleGridIndices[index - 1];
		if (currGridIndex != prevGridIndex) {
			gridCellStartIndices[currGridIndex] = index;
			gridCellEndIndices[prevGridIndex] = index-1;
		}
	}
}



__global__ void kernUpdateVelNeighborSearchScattered(
	int N, int gridResolution, glm::vec3 gridMin,
	float inverseCellWidth, float cellWidth,
	int* gridCellStartIndices, int* gridCellEndIndices,
	float searchDistance,
	int* particleArrayIndices,
	glm::vec3* pos, glm::vec3* vel1, glm::vec3* vel2) {
	// TODO-2.1 - Update a boid's velocity using the uniform grid to reduce
	// the number of boids that need to be checked.
	
	// Step 1 - Identify the grid cell that this particle is in
	int boidIndex = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (boidIndex >= N) {
		return;
	}
	glm::vec3 boidPos = pos[boidIndex];

	// Step 2 - Identify which cells may contain neighbors. This isn't always 8.
	float search = 2*searchDistance/cellWidth;
	glm::vec3 currGridIndices = floor((boidPos - gridMin) * inverseCellWidth);
	int minX = glm::fract(currGridIndices.x) <= 0.5f ? currGridIndices.x - search : currGridIndices.x;
	int minY = glm::fract(currGridIndices.y) <= 0.5f ? currGridIndices.y - search : currGridIndices.y;
	int minZ = glm::fract(currGridIndices.z) <= 0.5f ? currGridIndices.z - search : currGridIndices.z;
	int maxX = glm::fract(currGridIndices.x) > 0.5f ? currGridIndices.x + search : currGridIndices.x;
	int maxY = glm::fract(currGridIndices.y) > 0.5f ? currGridIndices.y + search : currGridIndices.y;
	int maxZ = glm::fract(currGridIndices.z) > 0.5f ? currGridIndices.z + search : currGridIndices.z;

	// Variables for rule 1
	glm::vec3 perceivedCenter(0.f, 0.f, 0.f);
	int numNeighbors1 = 0;
	// Variables for rule 2
	glm::vec3 c(0.f, 0.f, 0.f);
	// Variables for rule 3
	glm::vec3 perceivedVelocity(0.f, 0.f, 0.f);
	int numNeighbors3 = 0;

	for (int z = minZ; z <= maxZ; z++) {
		for (int y = minY; y <= maxY; y++) {
			for (int x = minX; x <= maxX; x++) {
				int gridIndex = gridIndex3Dto1D(x, y, z, gridResolution);
				if (gridCellStartIndices[gridIndex] != -1) // -1 means the cell is empty
				{
					// - For each cell, read the start/end indices in the boid pointer array.
					//   DIFFERENCE: For best results, consider what order the cells should be
					//   checked in to maximize the memory benefits of reordering the boids data.
					for (int b = gridCellStartIndices[gridIndex]; b <= gridCellEndIndices[gridIndex]; b++) {
						// - Access each boid in the cell and compute velocity change from
						// the boids rules, if this boid is within the neighborhood distance.
						int particleIndex = particleArrayIndices[b];
						if (particleIndex != boidIndex) {
							// Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
							float distance = glm::distance(boidPos, pos[particleIndex]);
							if (distance < rule1Distance) {
								perceivedCenter += pos[particleIndex];
								numNeighbors1++;
							}
							// Rule 2: boids try to stay a distance d away from each other
							if (distance < rule2Distance) {
								c -= (pos[particleIndex] - boidPos);
							}
							// Rule 3: boids try to match the speed of surrounding boids
							if (distance < rule3Distance) {
								perceivedVelocity += vel1[particleIndex];
								numNeighbors3++;
							}
						}
					}
				}
			}
		}
	}

	glm::vec3 newVelocity = vel1[boidIndex];
	// Rule 1 change
	if (numNeighbors1 > 0) {
		perceivedCenter /= numNeighbors1;
		newVelocity += ((perceivedCenter - boidPos) * rule1Scale);
	}
	// Rule 2 change
	newVelocity += c * rule2Scale;

	// Rule 3 change
	if (numNeighbors3 > 0) {
		perceivedVelocity /= numNeighbors3;
		newVelocity += (perceivedVelocity * rule3Scale);
	}

	// - Clamp the speed change before putting the new speed in vel2
	if (glm::length(newVelocity) > maxSpeed) {
		newVelocity = glm::normalize(newVelocity);
	}
	vel2[boidIndex] = newVelocity;
}

__global__ void kernUpdateVelNeighborSearchCoherent(
	int N, int gridResolution, glm::vec3 gridMin,
	float inverseCellWidth, float cellWidth,
	int* gridCellStartIndices, int* gridCellEndIndices,
	float searchDistance,
	glm::vec3* pos, glm::vec3* vel1, glm::vec3* vel2) {
	// TODO-2.3 - This should be very similar to kernUpdateVelNeighborSearchScattered,
	// except with one less level of indirection.
	// This should expect gridCellStartIndices and gridCellEndIndices to refer
	// directly to pos and vel1.
	// 
	// - Identify the grid cell that this particle is in
	int boidIndex = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (boidIndex >= N) {
		return;
	}
	glm::vec3 boidPos = pos[boidIndex];

	// - Identify which cells may contain neighbors. This isn't always 8.
	float search = 2 * searchDistance / cellWidth;
	glm::vec3 currGridIndices = floor((boidPos - gridMin) * inverseCellWidth);
	int minX = glm::fract(currGridIndices.x) <= 0.5f ? currGridIndices.x - search : currGridIndices.x;
	int minY = glm::fract(currGridIndices.y) <= 0.5f ? currGridIndices.y - search : currGridIndices.y;
	int minZ = glm::fract(currGridIndices.z) <= 0.5f ? currGridIndices.z - search : currGridIndices.z;
	int maxX = glm::fract(currGridIndices.x) > 0.5f ? currGridIndices.x + search : currGridIndices.x;
	int maxY = glm::fract(currGridIndices.y) > 0.5f ? currGridIndices.y + search : currGridIndices.y;
	int maxZ = glm::fract(currGridIndices.z) > 0.5f ? currGridIndices.z + search : currGridIndices.z;

	// Variables for rule 1
	glm::vec3 perceivedCenter(0.f, 0.f, 0.f);
	int numNeighbors1 = 0;
	// Variables for rule 2
	glm::vec3 c(0.f, 0.f, 0.f);
	// Variables for rule 3
	glm::vec3 perceivedVelocity(0.f, 0.f, 0.f);
	int numNeighbors3 = 0;

	// - For each cell, read the start/end indices in the boid pointer array.
	for (int z = minZ; z <= maxZ; z++) {
		for (int y = minY; y <= maxY; y++) {
			for (int x = minX; x <= maxX; x++) {
				int gridIndex = gridIndex3Dto1D(x, y, z, gridResolution);
				if (gridCellStartIndices[gridIndex] != -1) // -1 means the cell is empty
				{
					// - For each cell, read the start/end indices in the boid pointer array.
					for (int b = gridCellStartIndices[gridIndex]; b <= gridCellEndIndices[gridIndex]; b++) {
						// - Access each boid in the cell and compute velocity change from
						// the boids rules, if this boid is within the neighborhood distance.
						// Rule 1: boids fly towards their local perceived center of mass, which excludes themselves
						if (b != boidIndex) {
							float distance = glm::distance(boidPos, pos[b]);
							if (distance < rule1Distance) {
								perceivedCenter += pos[b];
								numNeighbors1++;
							}
							// Rule 2: boids try to stay a distance d away from each other
							if (distance < rule2Distance) {
								c -= (pos[b] - boidPos);
							}
							// Rule 3: boids try to match the speed of surrounding boids
							if (distance < rule3Distance) {
								perceivedVelocity += vel1[b];
								numNeighbors3++;
							}
						}
					}
				}
			}
		}
	}

	glm::vec3 newVelocity = vel1[boidIndex];
	// Rule 1 change
	if (numNeighbors1 > 0) {
		perceivedCenter /= numNeighbors1;
		newVelocity += ((perceivedCenter - boidPos) * rule1Scale);
	}
	// Rule 2 change
	newVelocity += c * rule2Scale;

	// Rule 3 change
	if (numNeighbors3 > 0) {
		perceivedVelocity /= numNeighbors3;
		newVelocity += (perceivedVelocity * rule3Scale);
	}

	// - Clamp the speed change before putting the new speed in vel2
	if (glm::length(newVelocity) > maxSpeed) {
		newVelocity = glm::normalize(newVelocity);
	}
	vel2[boidIndex] = newVelocity;

	//   DIFFERENCE: For best results, consider what order the cells should be
	//   checked in to maximize the memory benefits of reordering the boids data.
	// - Access each boid in the cell and compute velocity change from
	//   the boids rules, if this boid is within the neighborhood distance.
	// - Clamp the speed change before putting the new speed in vel2
}

__global__ void kernReorderPosAndVelData(int N, int* particleArrayIndices, glm::vec3* pos, glm::vec3* pos_reordered, glm::vec3* vel1, glm::vec3* vel2) {
	// ALGORITHM (can be parallelized):
	// 1. Iterate through the re-ordered dev_particleArrayIndices
	// 2. For each dev_particleArrayIndices[i], use it to index into the dev_pos/dev_vel array
	// 3. Put the value into dev_new_pos/vel[i]
	int boidIndex = (blockIdx.x * blockDim.x) + threadIdx.x;
	if (boidIndex >= N) {
		return;
	}
	int index = particleArrayIndices[boidIndex] ;
	pos_reordered[boidIndex] = pos[index];
	vel2[boidIndex] = vel1[index];
}

/**
* Step the entire N-body simulation by `dt` seconds.
*/
void Boids::stepSimulationNaive(float dt) {
	// TODO-1.2 - use the kernels you wrote to step the simulation forward in time.
	// TODO-1.2 ping-pong the velocity buffers
	int N = numObjects;
	dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);
	kernUpdateVelocityBruteForce <<< fullBlocksPerGrid, blockSize >>> (numObjects, dev_pos, dev_vel1, dev_vel2);
	kernUpdatePos <<< fullBlocksPerGrid, blockSize >>> (numObjects, dt, dev_pos, dev_vel2);

	glm::vec3* temp = dev_vel1;
	dev_vel1 = dev_vel2;
	dev_vel2 = temp;
}

void Boids::stepSimulationScatteredGrid(float dt) {
	// TODO-2.1
	// Uniform Grid Neighbor search using Thrust sort.
	int N = numObjects;
	dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);
	// In Parallel:
	// - label each particle with its array index as well as its grid index.
	//   Use 2x width grids.
	dim3 gridFullBlocksPerGrid((gridCellCount + blockSize - 1) / blockSize);
	kernResetIntBuffer << < gridFullBlocksPerGrid, blockSize >> > (gridCellCount, dev_gridCellStartIndices, -1);

	kernComputeIndices << < fullBlocksPerGrid, blockSize >> > (N, gridCellWidth, gridMinimum, gridInverseCellWidth, dev_pos, dev_particleArrayIndices, dev_particleGridIndices);
	// - Unstable key sort using Thrust. A stable sort isn't necessary, but you
	//   are welcome to do a performance comparison.
	dev_thrust_particleArrayIndices = thrust::device_ptr<int>(dev_particleArrayIndices);
	dev_thrust_particleGridIndices = thrust::device_ptr<int>(dev_particleGridIndices);
	thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + N, dev_thrust_particleArrayIndices);
	// - Naively unroll the loop for finding the start and end indices of each
	//   cell's data pointers in the array of boid indices
	kernIdentifyCellStartEnd <<< fullBlocksPerGrid, blockSize >> > (N, dev_particleGridIndices, dev_gridCellStartIndices, dev_gridCellEndIndices);
	// - Perform velocity updates using neighbor search
	kernUpdateVelNeighborSearchScattered << < fullBlocksPerGrid, blockSize >> > (N, gridCellWidth, gridMinimum, gridInverseCellWidth, gridCellWidth, dev_gridCellStartIndices, dev_gridCellEndIndices, neighborhoodDistance, dev_particleArrayIndices, dev_pos, dev_vel1, dev_vel2);
	// - Update positions
	kernUpdatePos << < fullBlocksPerGrid, blockSize >> > (N, dt, dev_pos, dev_vel2);

	// - Ping-pong buffers as needed
	glm::vec3* temp = dev_vel1;
	dev_vel1 = dev_vel2;
	dev_vel2 = temp;
}

void Boids::stepSimulationCoherentGrid(float dt) {
	// TODO-2.3 - start by copying Boids::stepSimulationNaiveGrid
	// Uniform Grid Neighbor search using Thrust sort on cell-coherent data.
	int N = numObjects;
	dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);
	
	// In Parallel:
	// - Label each particle with its array index as well as its grid index.
	//   Use 2x width grids
	dim3 gridFullBlocksPerGrid((gridCellCount + blockSize - 1) / blockSize);
	kernResetIntBuffer << < gridFullBlocksPerGrid, blockSize >> > (gridCellCount, dev_gridCellEndIndices, -1);
	kernComputeIndices << < fullBlocksPerGrid, blockSize >> > (N, gridCellWidth, gridMinimum, gridInverseCellWidth, dev_pos, dev_particleArrayIndices, dev_particleGridIndices);
	// - Unstable key sort using Thrust. A stable sort isn't necessary, but you
	//   are welcome to do a performance comparison.
	dev_thrust_particleArrayIndices = thrust::device_ptr<int>(dev_particleArrayIndices);
	dev_thrust_particleGridIndices = thrust::device_ptr<int>(dev_particleGridIndices);

	thrust::sort_by_key(dev_thrust_particleGridIndices, dev_thrust_particleGridIndices + N, dev_thrust_particleArrayIndices);

	// - Naively unroll the loop for finding the start and end indices of each
	//   cell's data pointers in the array of boid indices
	kernIdentifyCellStartEnd << < fullBlocksPerGrid, blockSize >> > (N, dev_particleGridIndices, dev_gridCellStartIndices, dev_gridCellEndIndices);
	// - BIG DIFFERENCE: use the rearranged array index buffer to reshuffle all
	//   the particle data in the simulation array.
	//   CONSIDER WHAT ADDITIONAL BUFFERS YOU NEED
	// buffer to keep the original array indices
	kernReorderPosAndVelData << < fullBlocksPerGrid, blockSize >> > (N, dev_particleArrayIndices, dev_pos, dev_pos_reordered, dev_vel1, dev_vel2);
	// - Perform velocity updates using neighbor search
	kernUpdateVelNeighborSearchCoherent << < fullBlocksPerGrid, blockSize >> > (N, gridCellWidth, gridMinimum, gridInverseCellWidth, gridCellWidth, dev_gridCellStartIndices, dev_gridCellEndIndices, neighborhoodDistance, dev_pos_reordered, dev_vel2, dev_vel1);
	// - Update positions
	kernUpdatePos << < fullBlocksPerGrid, blockSize >> > (N, dt, dev_pos_reordered, dev_vel1);
	// - Ping-pong buffers as needed
	glm::vec3* temp = dev_pos;
	dev_pos = dev_pos_reordered;
	dev_pos_reordered = temp;
}

void Boids::endSimulation() {
	cudaFree(dev_vel1);
	cudaFree(dev_vel2);
	cudaFree(dev_pos);

	cudaFree(dev_pos_reordered);


	// TODO-2.1 TODO-2.3 - Free any additional buffers here.
	cudaFree(dev_particleArrayIndices);
	cudaFree(dev_particleGridIndices);
	cudaFree(dev_gridCellStartIndices);
	cudaFree(dev_gridCellEndIndices);
}

void Boids::unitTest() {
	// LOOK-1.2 Feel free to write additional tests here.

	// test unstable sort
	int* dev_intKeys;
	int* dev_intValues;
	int N = 10;

	std::unique_ptr<int[]>intKeys{ new int[N] };
	std::unique_ptr<int[]>intValues{ new int[N] };

	intKeys[0] = 0; intValues[0] = 0;
	intKeys[1] = 1; intValues[1] = 1;
	intKeys[2] = 0; intValues[2] = 2;
	intKeys[3] = 3; intValues[3] = 3;
	intKeys[4] = 0; intValues[4] = 4;
	intKeys[5] = 2; intValues[5] = 5;
	intKeys[6] = 2; intValues[6] = 6;
	intKeys[7] = 0; intValues[7] = 7;
	intKeys[8] = 5; intValues[8] = 8;
	intKeys[9] = 6; intValues[9] = 9;

	cudaMalloc((void**)&dev_intKeys, N * sizeof(int));
	checkCUDAErrorWithLine("cudaMalloc dev_intKeys failed!");

	cudaMalloc((void**)&dev_intValues, N * sizeof(int));
	checkCUDAErrorWithLine("cudaMalloc dev_intValues failed!");

	dim3 fullBlocksPerGrid((N + blockSize - 1) / blockSize);

	std::cout << "before unstable sort: " << std::endl;
	for (int i = 0; i < N; i++) {
		std::cout << "  key: " << intKeys[i];
		std::cout << " value: " << intValues[i] << std::endl;
	}

	// How to copy data to the GPU
	cudaMemcpy(dev_intKeys, intKeys.get(), sizeof(int) * N, cudaMemcpyHostToDevice);
	cudaMemcpy(dev_intValues, intValues.get(), sizeof(int) * N, cudaMemcpyHostToDevice);

	// Wrap device vectors in thrust iterators for use with thrust.
	thrust::device_ptr<int> dev_thrust_keys(dev_intKeys);
	thrust::device_ptr<int> dev_thrust_values(dev_intValues);
	// LOOK-2.1 Example for using thrust::sort_by_key
	thrust::sort_by_key(dev_thrust_keys, dev_thrust_keys + N, dev_thrust_values);

	// How to copy data back to the CPU side from the GPU
	cudaMemcpy(intKeys.get(), dev_intKeys, sizeof(int) * N, cudaMemcpyDeviceToHost);
	cudaMemcpy(intValues.get(), dev_intValues, sizeof(int) * N, cudaMemcpyDeviceToHost);
	checkCUDAErrorWithLine("memcpy back failed!");

	std::cout << "after unstable sort: " << std::endl;
	for (int i = 0; i < N; i++) {
		std::cout << "  key: " << intKeys[i];
		std::cout << " value: " << intValues[i] << std::endl;
	}

	// cleanup
	cudaFree(dev_intKeys);
	cudaFree(dev_intValues);
	checkCUDAErrorWithLine("cudaFree failed!");
	return;
}
