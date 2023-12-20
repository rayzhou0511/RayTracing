# include "graph.h"

# include <iostream>
# include <chrono> 

# define PIXELS_PER_THREAD 32

__device__ float intersect(const Object& obj, const vec3& origin, const vec3& dir){
    switch(obj.type){
        case SPHERE:{
            const vec3 OC = obj.position - origin;

            if (glm::length(OC) < obj.radius || glm::dot(OC, dir) < 0) return infinity;

            float l        = glm::length(glm::dot(OC, dir));
            float m_square = glm::length(OC) * glm::length(OC) - l * l;
            float q_square = obj.radius * obj.radius - m_square;

            return (q_square >= 0) ? (l - sqrtf(q_square)) : infinity;
        }
        case PLANE: {
            float dn = glm::dot(dir, obj.normal);
    
            if (abs(dn) < 1e-6) { return infinity; }
            
            float d = glm::dot(obj.position - origin, obj.normal) / dn;
            
            return d > 0 ? d : infinity;
        }
    }
}

__device__ vec3 get_normal(const Object& obj, const vec3& point){
    switch (obj.type) {
        case SPHERE:
            return glm::normalize(point - obj.position);
        case PLANE:
            return obj.normal;
    }
}

__device__ vec3 intersect_color(
    vec3 origin, vec3 dir, 
    const float initial_intensity, 
    const Object* dev_scene
){
    vec3 final_color = vec3(0., 0., 0.);
    float intensity = initial_intensity;

    for (int depth = 0; depth < MAX_DEPTH; ++depth) {
        if (intensity < 0.01) break;

        float min_distance = infinity;
        size_t obj_index = invalid_idx;
        for (size_t i = 0; i < numObjects; ++i) {
            float current_distance = intersect(dev_scene[i], origin, dir);
            if (current_distance < min_distance) {
                min_distance = current_distance;
                obj_index = i;
            }
        }

        if (min_distance == infinity) break;
        
        const Object& obj = dev_scene[obj_index];
        vec3 c            = ambient * obj.color;
        const vec3 P      = origin + dir * min_distance;
        const vec3 PL     = glm::normalize(light_point - P);
        const vec3 PO     = glm::normalize(origin - P);
        const vec3 N      = get_normal(obj, P);

        /*shadow test*/
        bool in_shadow = false;
        for (size_t i = 0; i < numObjects; ++i) {
            if (i != obj_index){
                float intersection = intersect(dev_scene[i], P + N * .0001f, PL);
                if (intersection < glm::length(PL)){
                    in_shadow = true;
                    break;
                }
            }
        }

        if (!in_shadow) {
            c += obj.diffuse * fmaxf(glm::dot(N, PL), 0.f) * obj.color * light_color;
            c += obj.specular_coef * powf(fmaxf(glm::dot(N, glm::normalize(PL + PO)), 0.f), obj.specular_k) * light_color;
        }

        final_color += intensity * c;
        if (obj.reflection <= 0) break;

        dir = dir - 2 * glm::dot(dir, N) * N;
        origin = P + N * .0001f;
        intensity *= obj.reflection;
    }

    return glm::clamp(final_color, 0.f, 1.f);
}

__global__ void rendering_kernel(
    const float lowerX, const float lowerY,
    const float upperX, const float upperY,
    const float stepX, const float stepY,
    const int w, const int h, 
    const Object* dev_scene, vec3* gpu_output,
    const vec3 camera_dir, const vec3 camera_right, const vec3 camera_up,
    int pixelsPerThread
){

    int startX = blockIdx.x * blockDim.x * pixelsPerThread + threadIdx.x;
    int startY = blockIdx.y * blockDim.y * pixelsPerThread + threadIdx.y;

    for (int i = 0; i < pixelsPerThread; i++) {
        for (int j = 0; j < pixelsPerThread; j++) {
            int thisX = startX + i;
            int thisY = startY + j;

            if (thisX >= w || thisY >= h) continue;

            float u = upperX - thisX * stepX;
            float v = upperY - thisY * stepY;

            vec3 direction = glm::normalize(camera_dir + u * camera_right + v * camera_up);

            int index = thisY * w + thisX;
            gpu_output[index] = intersect_color(camera_pos, direction, 1, dev_scene);
        }
    }
}

void rendering(
    const int w, const int h,
    const std::string filename
){
    
    const float r     = float(w) / h;                                    // aspect ratio
    const glm::vec4 S = glm::vec4(-1., -1. / r + .25, 1., 1. / r + .25); // view frustum

    const vec3 camera_dir   = glm::normalize(camera_target - camera_pos);
    const vec3 camera_right = glm::normalize(glm::cross(camera_dir, vec3(0, 1, 0)));
    const vec3 camera_up    = glm::normalize(glm::cross(camera_right, camera_dir)); 

    const float stepX = (S.z - S.x) / (w - 1);
    const float stepY = (S.w - S.y) / (h - 1);

    /* setup dev_scene */
    Object *dev_scene;
    cudaMalloc(&dev_scene, sizeof(host_scene));
    cudaMemcpy(dev_scene, host_scene, sizeof(host_scene), cudaMemcpyHostToDevice);

    /* setup dev_output */
    size_t pitch;
    vec3 *gpu_output; // dev output
    cudaMallocPitch(&gpu_output, &pitch, w * sizeof(vec3), h);

    // Use cudaHostAlloc for host output
    vec3 *host_output;
    cudaHostAlloc((void**)&host_output, h * pitch, cudaHostAllocDefault);

    dim3 blockSize(16, 16); 
    dim3 gridSize((w + blockSize.x * PIXELS_PER_THREAD - 1) / (blockSize.x * PIXELS_PER_THREAD),
                  (h + blockSize.y * PIXELS_PER_THREAD - 1) / (blockSize.y * PIXELS_PER_THREAD));

    auto start_time = std::chrono::high_resolution_clock::now();

    rendering_kernel<<<gridSize, blockSize>>>(
        S.x, S.y, 
        S.z, S.w, 
        stepX, stepY, 
        w, h, 
        dev_scene, gpu_output,
        camera_dir, camera_right, camera_up,
        PIXELS_PER_THREAD
    );

    cv::Mat img(h, w, CV_32FC3);
    cudaMemcpy(img.data, gpu_output, outputSize, cudaMemcpyDeviceToHost);

    img *= 255;
    img.convertTo(img, CV_8UC3);
    cv::imwrite(filename, img);

    auto end_time = std::chrono::high_resolution_clock::now();
    auto duration = std::chrono::duration_cast<std::chrono::milliseconds>(end_time - start_time);
    std::cout << "Rendering completed in " << duration.count() << " milliseconds." << std::endl;    

    cudaFree(dev_scene);
    cudaFree(gpu_output);
}