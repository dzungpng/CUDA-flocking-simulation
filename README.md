CUDA Flocking Simulation 🐠 🦩
=============================
_Source: University of Pennsylvania, [CIS 565: GPU Programming and Architecture](https://cis565-fall-2021.github.io/)_

A CUDA and C++ implementation of the famous [Raynolds Boids flocking algorithm](https://en.wikipedia.org/wiki/Boids). The implementation is further optimized with a uniform and coherent grid search, which restrict the search radius of each boid and organize boid data such that they can be conveniently accessed (contiguous in memory).

## Developer Machine Specs 💻

GCP Windows Server 2016, Intel(R) Zeon(R) CPU @ 2.30GHz 32GB, NVIDIA Testla T4 (TU104) 15360MB

[How to set up a GPU-accelerated windows workstation with GCP](https://cloud.google.com/architecture/creating-a-virtual-gpu-accelerated-windows-workstation)

## Gallery 🖼️

**Specs for all images in the gallery:** \
Number of boids: 50,000 \
Boid speed multiplier: 1.0 \
Grid scale: 100 \
Blocksize (used for CUDA kernel launch): 1024

### Image 1 and 2: Naive Grid Implementation 

![](./media/boids_naive.gif)
_Innitially_
![](./media/boids_naive_later.gif)
_After ~20 seconds_


### Image 3: Uniform and Coherent Grid Implementation
![](./media/boids_coherent.gif)

## Performance Analysis 📈
*Note: the measurements below are done without visualization*

### Graph 1: Framerate change with increasing # of boids for [naive](https://github.com/dzungpng/CUDA-flocking-simulation/blob/main/INSTRUCTION.md#11-boids-with-naive-neighbor-search), [scattered uniform](https://github.com/dzungpng/CUDA-flocking-simulation/blob/main/INSTRUCTION.md#20-a-quick-explanation-of-uniform-grids), and [coherent uniform grid](https://github.com/dzungpng/CUDA-flocking-simulation/blob/main/INSTRUCTION.md#23-cutting-out-the-middleman).

![](./media/graph_boids_vs_fps.PNG)

### Graph 2: Framerate change with increasing [block](https://en.wikipedia.org/wiki/Thread_block_(CUDA_programming)) size
Number of boids: 100,000 \
Algorithm: Uniform and Coherent Grid

![](./media/graph_blocksize_vs_fps.PNG)

## Reflections 🤔

Reasons for decreasing FPS with increasing # of boids:
- More boid neighbors to check and process
- Larger data structures = high cost of "ping-pong" method and data management

Reason for decreasing FPS with block size < 128:
- Smaller block sizes results in more blocks assigned to cores, which can lead to higher cost to manage

Reason for decreasing FPS with block size > 128:
- Larger block sizes causes higher latency because they require the SM assigned to use more warp cycles (an SM runs 8 threads in a cycle; high block sizes = more threads per block = more warp cycles per block) 
