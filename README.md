# CUDA Flocking Simulation
_Source: University of Pennsylvania, [CIS 565: GPU Programming and Architecture](https://cis565-fall-2021.github.io/)_

A CUDA and C++ implementation of the famous [Raynolds Boids flocking algorithm](https://en.wikipedia.org/wiki/Boids). The implementation is further optimized with a uniform and coherent grid search, which restrict the search radius of each boid and organize boid data such that they can be conveniently accessed (contiguous in memory).

## Developer Machine Specs 💻
GCP Windows Server 2016, Intel(R) Zeon(R) CPU @ 2.30GHz 32GB, NVIDIA Testla T4 (TU104) 15360MB

[How to set up a GPU-accelerated windows workstation with GCP](https://cloud.google.com/architecture/creating-a-virtual-gpu-accelerated-windows-workstation)

## Gallery 🖼️

### Image 1 and 2: Naive Grid Implementation 
![boids](./media/boids_naive.gif)
![boids](./media/boids_naive_later.gif)

### Image 3: Uniform and Coherent Grid Implementation
![boids](./media/boids_coherent.gif)

## Performance Analysis 📈

### Graph 1 and 2: Framerate change with increasing # of boids for [naive](https://github.com/dzungpng/CUDA-flocking-simulation/blob/main/INSTRUCTION.md#11-boids-with-naive-neighbor-search), [scattered uniform](https://github.com/dzungpng/CUDA-flocking-simulation/blob/main/INSTRUCTION.md#20-a-quick-explanation-of-uniform-grids), and [coherent uniform grid](https://github.com/dzungpng/CUDA-flocking-simulation/blob/main/INSTRUCTION.md#23-cutting-out-the-middleman).

[Insert graph]
_With visualization_

[Insert graph]
_Without visualization_

### Graph 3: Framerate chagne with increasing [block](https://en.wikipedia.org/wiki/Thread_block_(CUDA_programming)) size