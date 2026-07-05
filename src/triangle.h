/* triangle.h --- Minimal self-contained Vulkan triangle renderer.

   Defines VulkanExampleBase and VulkanExample, the interface expected by
   VulkanView.mm / VulkanDelegate.mm.  Renders a single RGB triangle to a
   CAMetalLayer via MoltenVK (VK_EXT_metal_surface).

   The shader SPIR-V is embedded (triangle_shaders.h); the vertex data is
   hardcoded in the vertex shader, so no vertex buffers are needed.  */

#pragma once

#ifdef __OBJC__
#import <QuartzCore/CAMetalLayer.h>
#endif

#include <vulkan/vulkan.h>
#include <vulkan/vulkan_metal.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include "triangle_shaders.h"

#define VK_CHECK(x)                                                         \
  do {                                                                      \
    VkResult err__ = (x);                                                   \
    if (err__ != VK_SUCCESS) {                                              \
      fprintf(stderr, "Vulkan error %d at %s:%d\n", err__, __FILE__,        \
              __LINE__);                                                    \
    }                                                                       \
  } while (0)

class VulkanExampleBase {
public:
  virtual ~VulkanExampleBase() {}
  virtual void initVulkan() = 0;
  virtual void setupWindow(void *metalLayer) = 0;
  virtual void prepare() = 0;
  virtual void render() = 0;
  virtual void displayLinkOutputCb() = 0;
  virtual void windowWillResize(double w, double h) = 0;
  virtual void viewChanged() = 0;
  virtual void updateOverlay() = 0;
};

class VulkanExample : public VulkanExampleBase {
public:
  VulkanExample() {}
  ~VulkanExample() override { cleanup(); }

  void initVulkan() override {
    createInstance();
  }

  /* metalLayer is a CAMetalLayer* (as void*).  */
  void setupWindow(void *metalLayer) override {
    layer_ = metalLayer;
  }

  void prepare() override {
    if (!instance_) return;
    createSurface();
    if (surface_ == VK_NULL_HANDLE) return;
    pickPhysicalDevice();
    if (phys_ == VK_NULL_HANDLE) return;
    createDevice();
    if (device_ == VK_NULL_HANDLE) return;  /* extension/device failure */
    createSwapchain();
    createRenderPass();
    createPipeline();
    createFramebuffers();
    createCommandPool();
    createSyncObjects();
    prepared_ = true;
    render();
  }

  void render() override {
    if (!prepared_) return;
    drawFrame();
  }

  void displayLinkOutputCb() override { /* driven by MTKView draw loop */ }

  void windowWillResize(double w, double h) override {
    pendingWidth_ = (uint32_t)w;
    pendingHeight_ = (uint32_t)h;
    resizePending_ = true;
  }

  void viewChanged() override {
    if (resizePending_ && prepared_)
      recreateSwapchain();
  }

  void updateOverlay() override {}

private:
  /* --- state --- */
  void *layer_ = nullptr;
  VkInstance instance_ = VK_NULL_HANDLE;
  VkSurfaceKHR surface_ = VK_NULL_HANDLE;
  VkPhysicalDevice phys_ = VK_NULL_HANDLE;
  VkDevice device_ = VK_NULL_HANDLE;
  VkQueue queue_ = VK_NULL_HANDLE;
  uint32_t queueFamily_ = 0;
  VkSwapchainKHR swapchain_ = VK_NULL_HANDLE;
  VkFormat swapFormat_ = VK_FORMAT_B8G8R8A8_UNORM;
  VkExtent2D extent_ = {800, 600};
  std::vector<VkImage> images_;
  std::vector<VkImageView> views_;
  std::vector<VkFramebuffer> framebuffers_;
  VkRenderPass renderPass_ = VK_NULL_HANDLE;
  VkPipelineLayout pipelineLayout_ = VK_NULL_HANDLE;
  VkPipeline pipeline_ = VK_NULL_HANDLE;
  VkCommandPool cmdPool_ = VK_NULL_HANDLE;
  VkSemaphore acquireSem_ = VK_NULL_HANDLE;
  VkSemaphore renderSem_ = VK_NULL_HANDLE;
  VkFence inFlight_ = VK_NULL_HANDLE;
  bool prepared_ = false;
  bool resizePending_ = false;
  uint32_t pendingWidth_ = 0, pendingHeight_ = 0;

  /* --- setup --- */
  void createInstance() {
    VkApplicationInfo app{};
    app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app.pApplicationName = "emacs-xwidget-vulkan";
    app.apiVersion = VK_API_VERSION_1_1;

    const char *exts[] = {
      VK_KHR_SURFACE_EXTENSION_NAME,
      VK_EXT_METAL_SURFACE_EXTENSION_NAME,
      VK_KHR_PORTABILITY_ENUMERATION_EXTENSION_NAME,
    };
    VkInstanceCreateInfo ci{};
    ci.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    ci.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
    ci.pApplicationInfo = &app;
    ci.enabledExtensionCount = sizeof(exts) / sizeof(exts[0]);
    ci.ppEnabledExtensionNames = exts;
    VK_CHECK(vkCreateInstance(&ci, nullptr, &instance_));
  }

  void createSurface() {
    if (!instance_ || !layer_) return;
    VkMetalSurfaceCreateInfoEXT ci{};
    ci.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT;
    ci.pLayer = (const CAMetalLayer *)layer_;
    auto fn = (PFN_vkCreateMetalSurfaceEXT)vkGetInstanceProcAddr(
        instance_, "vkCreateMetalSurfaceEXT");
    if (fn)
      VK_CHECK(fn(instance_, &ci, nullptr, &surface_));
    else
      fprintf(stderr, "vkCreateMetalSurfaceEXT not available\n");
  }

  void pickPhysicalDevice() {
    uint32_t n = 0;
    vkEnumeratePhysicalDevices(instance_, &n, nullptr);
    if (!n) { fprintf(stderr, "no Vulkan devices\n"); return; }
    std::vector<VkPhysicalDevice> devs(n);
    vkEnumeratePhysicalDevices(instance_, &n, devs.data());
    phys_ = devs[0];

    uint32_t qn = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(phys_, &qn, nullptr);
    std::vector<VkQueueFamilyProperties> qs(qn);
    vkGetPhysicalDeviceQueueFamilyProperties(phys_, &qn, qs.data());
    for (uint32_t i = 0; i < qn; ++i) {
      VkBool32 present = VK_FALSE;
      vkGetPhysicalDeviceSurfaceSupportKHR(phys_, i, surface_, &present);
      if ((qs[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) && present) {
        queueFamily_ = i;
        break;
      }
    }
  }

  void createDevice() {
    float prio = 1.0f;
    VkDeviceQueueCreateInfo qci{};
    qci.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    qci.queueFamilyIndex = queueFamily_;
    qci.queueCount = 1;
    qci.pQueuePriorities = &prio;

    /* Enumerate the extensions this device actually advertises and only
       enable the ones present.  vkCreateDevice returns
       VK_ERROR_EXTENSION_NOT_PRESENT (-7) if we request an unsupported
       one.  VK_KHR_swapchain is required; VK_KHR_portability_subset
       must be enabled *if* present (portability rule), but may be
       absent on some loader/ICD combinations.  */
    uint32_t extCount = 0;
    vkEnumerateDeviceExtensionProperties(phys_, nullptr, &extCount, nullptr);
    std::vector<VkExtensionProperties> avail(extCount);
    vkEnumerateDeviceExtensionProperties(phys_, nullptr, &extCount, avail.data());
    auto has = [&](const char *name) {
      for (auto &e : avail)
        if (strcmp(e.extensionName, name) == 0) return true;
      return false;
    };

    std::vector<const char *> exts;
    if (has(VK_KHR_SWAPCHAIN_EXTENSION_NAME))
      exts.push_back(VK_KHR_SWAPCHAIN_EXTENSION_NAME);
    else
      fprintf(stderr, "triangle: VK_KHR_swapchain not available\n");
    if (has("VK_KHR_portability_subset"))
      exts.push_back("VK_KHR_portability_subset");

    VkDeviceCreateInfo ci{};
    ci.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    ci.queueCreateInfoCount = 1;
    ci.pQueueCreateInfos = &qci;
    ci.enabledExtensionCount = (uint32_t)exts.size();
    ci.ppEnabledExtensionNames = exts.empty() ? nullptr : exts.data();
    VkResult r = vkCreateDevice(phys_, &ci, nullptr, &device_);
    if (r != VK_SUCCESS) {
      fprintf(stderr, "triangle: vkCreateDevice failed (%d)\n", r);
      device_ = VK_NULL_HANDLE;
      return;
    }
    vkGetDeviceQueue(device_, queueFamily_, 0, &queue_);
  }

  VkExtent2D chooseExtent(const VkSurfaceCapabilitiesKHR &caps) {
    if (caps.currentExtent.width != UINT32_MAX)
      return caps.currentExtent;
    VkExtent2D e = extent_;
    if (e.width < caps.minImageExtent.width) e.width = caps.minImageExtent.width;
    if (e.height < caps.minImageExtent.height) e.height = caps.minImageExtent.height;
    return e;
  }

  void createSwapchain() {
    VkSurfaceCapabilitiesKHR caps{};
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(phys_, surface_, &caps);
    extent_ = chooseExtent(caps);

    uint32_t fmtCount = 0;
    vkGetPhysicalDeviceSurfaceFormatsKHR(phys_, surface_, &fmtCount, nullptr);
    std::vector<VkSurfaceFormatKHR> fmts(fmtCount);
    vkGetPhysicalDeviceSurfaceFormatsKHR(phys_, surface_, &fmtCount, fmts.data());
    swapFormat_ = fmts[0].format;
    VkColorSpaceKHR space = fmts[0].colorSpace;
    for (auto &f : fmts)
      if (f.format == VK_FORMAT_B8G8R8A8_UNORM) { swapFormat_ = f.format; space = f.colorSpace; break; }

    uint32_t imgCount = caps.minImageCount + 1;
    if (caps.maxImageCount && imgCount > caps.maxImageCount)
      imgCount = caps.maxImageCount;

    VkSwapchainCreateInfoKHR ci{};
    ci.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    ci.surface = surface_;
    ci.minImageCount = imgCount;
    ci.imageFormat = swapFormat_;
    ci.imageColorSpace = space;
    ci.imageExtent = extent_;
    ci.imageArrayLayers = 1;
    ci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    ci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    ci.preTransform = caps.currentTransform;
    ci.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    ci.presentMode = VK_PRESENT_MODE_FIFO_KHR;
    ci.clipped = VK_TRUE;
    VK_CHECK(vkCreateSwapchainKHR(device_, &ci, nullptr, &swapchain_));

    uint32_t n = 0;
    vkGetSwapchainImagesKHR(device_, swapchain_, &n, nullptr);
    images_.resize(n);
    vkGetSwapchainImagesKHR(device_, swapchain_, &n, images_.data());

    views_.resize(n);
    for (uint32_t i = 0; i < n; ++i) {
      VkImageViewCreateInfo iv{};
      iv.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
      iv.image = images_[i];
      iv.viewType = VK_IMAGE_VIEW_TYPE_2D;
      iv.format = swapFormat_;
      iv.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
      iv.subresourceRange.levelCount = 1;
      iv.subresourceRange.layerCount = 1;
      VK_CHECK(vkCreateImageView(device_, &iv, nullptr, &views_[i]));
    }
  }

  void createRenderPass() {
    VkAttachmentDescription color{};
    color.format = swapFormat_;
    color.samples = VK_SAMPLE_COUNT_1_BIT;
    color.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    color.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    color.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    color.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    color.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    color.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    VkAttachmentReference ref{};
    ref.attachment = 0;
    ref.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    VkSubpassDescription sub{};
    sub.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    sub.colorAttachmentCount = 1;
    sub.pColorAttachments = &ref;

    VkSubpassDependency dep{};
    dep.srcSubpass = VK_SUBPASS_EXTERNAL;
    dep.dstSubpass = 0;
    dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

    VkRenderPassCreateInfo ci{};
    ci.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    ci.attachmentCount = 1;
    ci.pAttachments = &color;
    ci.subpassCount = 1;
    ci.pSubpasses = &sub;
    ci.dependencyCount = 1;
    ci.pDependencies = &dep;
    VK_CHECK(vkCreateRenderPass(device_, &ci, nullptr, &renderPass_));
  }

  VkShaderModule makeShader(const uint32_t *code, size_t size) {
    VkShaderModuleCreateInfo ci{};
    ci.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    ci.codeSize = size;
    ci.pCode = code;
    VkShaderModule m = VK_NULL_HANDLE;
    VK_CHECK(vkCreateShaderModule(device_, &ci, nullptr, &m));
    return m;
  }

  void createPipeline() {
    VkShaderModule vs = makeShader(triangle_vert_spv, triangle_vert_spv_size);
    VkShaderModule fs = makeShader(triangle_frag_spv, triangle_frag_spv_size);

    VkPipelineShaderStageCreateInfo stages[2]{};
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vs;
    stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = fs;
    stages[1].pName = "main";

    VkPipelineVertexInputStateCreateInfo vin{};
    vin.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;

    VkPipelineInputAssemblyStateCreateInfo ia{};
    ia.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    ia.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

    VkViewport vp{0, 0, (float)extent_.width, (float)extent_.height, 0, 1};
    VkRect2D sc{{0, 0}, extent_};
    VkPipelineViewportStateCreateInfo vpState{};
    vpState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    vpState.viewportCount = 1;
    vpState.pViewports = &vp;
    vpState.scissorCount = 1;
    vpState.pScissors = &sc;

    VkDynamicState dyn[] = {VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR};
    VkPipelineDynamicStateCreateInfo dynState{};
    dynState.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynState.dynamicStateCount = 2;
    dynState.pDynamicStates = dyn;

    VkPipelineRasterizationStateCreateInfo rs{};
    rs.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rs.polygonMode = VK_POLYGON_MODE_FILL;
    rs.cullMode = VK_CULL_MODE_NONE;
    rs.frontFace = VK_FRONT_FACE_CLOCKWISE;
    rs.lineWidth = 1.0f;

    VkPipelineMultisampleStateCreateInfo ms{};
    ms.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    ms.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

    VkPipelineColorBlendAttachmentState cba{};
    cba.colorWriteMask = VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
                         VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
    VkPipelineColorBlendStateCreateInfo cb{};
    cb.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    cb.attachmentCount = 1;
    cb.pAttachments = &cba;

    VkPipelineLayoutCreateInfo pl{};
    pl.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    VK_CHECK(vkCreatePipelineLayout(device_, &pl, nullptr, &pipelineLayout_));

    VkGraphicsPipelineCreateInfo gp{};
    gp.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    gp.stageCount = 2;
    gp.pStages = stages;
    gp.pVertexInputState = &vin;
    gp.pInputAssemblyState = &ia;
    gp.pViewportState = &vpState;
    gp.pRasterizationState = &rs;
    gp.pMultisampleState = &ms;
    gp.pColorBlendState = &cb;
    gp.pDynamicState = &dynState;
    gp.layout = pipelineLayout_;
    gp.renderPass = renderPass_;
    gp.subpass = 0;
    VK_CHECK(vkCreateGraphicsPipelines(device_, VK_NULL_HANDLE, 1, &gp, nullptr,
                                       &pipeline_));

    vkDestroyShaderModule(device_, vs, nullptr);
    vkDestroyShaderModule(device_, fs, nullptr);
  }

  void createFramebuffers() {
    framebuffers_.resize(views_.size());
    for (size_t i = 0; i < views_.size(); ++i) {
      VkFramebufferCreateInfo ci{};
      ci.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
      ci.renderPass = renderPass_;
      ci.attachmentCount = 1;
      ci.pAttachments = &views_[i];
      ci.width = extent_.width;
      ci.height = extent_.height;
      ci.layers = 1;
      VK_CHECK(vkCreateFramebuffer(device_, &ci, nullptr, &framebuffers_[i]));
    }
  }

  void createCommandPool() {
    VkCommandPoolCreateInfo ci{};
    ci.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    ci.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    ci.queueFamilyIndex = queueFamily_;
    VK_CHECK(vkCreateCommandPool(device_, &ci, nullptr, &cmdPool_));
  }

  void createSyncObjects() {
    VkSemaphoreCreateInfo si{};
    si.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    vkCreateSemaphore(device_, &si, nullptr, &acquireSem_);
    vkCreateSemaphore(device_, &si, nullptr, &renderSem_);
    VkFenceCreateInfo fi{};
    fi.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    fi.flags = VK_FENCE_CREATE_SIGNALED_BIT;
    vkCreateFence(device_, &fi, nullptr, &inFlight_);
  }

  void recordCommandBuffer(VkCommandBuffer cmd, uint32_t imageIndex) {
    VkCommandBufferBeginInfo bi{};
    bi.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    vkBeginCommandBuffer(cmd, &bi);

    VkClearValue clear{};
    clear.color = {{0.1f, 0.1f, 0.15f, 1.0f}};
    VkRenderPassBeginInfo rp{};
    rp.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    rp.renderPass = renderPass_;
    rp.framebuffer = framebuffers_[imageIndex];
    rp.renderArea.extent = extent_;
    rp.clearValueCount = 1;
    rp.pClearValues = &clear;
    vkCmdBeginRenderPass(cmd, &rp, VK_SUBPASS_CONTENTS_INLINE);

    vkCmdBindPipeline(cmd, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline_);
    VkViewport vp{0, 0, (float)extent_.width, (float)extent_.height, 0, 1};
    VkRect2D sc{{0, 0}, extent_};
    vkCmdSetViewport(cmd, 0, 1, &vp);
    vkCmdSetScissor(cmd, 0, 1, &sc);
    vkCmdDraw(cmd, 3, 1, 0, 0);

    vkCmdEndRenderPass(cmd);
    vkEndCommandBuffer(cmd);
  }

  void drawFrame() {
    if (swapchain_ == VK_NULL_HANDLE) return;
    vkWaitForFences(device_, 1, &inFlight_, VK_TRUE, UINT64_MAX);

    uint32_t imageIndex = 0;
    VkResult acq = vkAcquireNextImageKHR(device_, swapchain_, UINT64_MAX,
                                         acquireSem_, VK_NULL_HANDLE,
                                         &imageIndex);
    if (acq == VK_ERROR_OUT_OF_DATE_KHR) { recreateSwapchain(); return; }
    vkResetFences(device_, 1, &inFlight_);

    VkCommandBufferAllocateInfo ai{};
    ai.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    ai.commandPool = cmdPool_;
    ai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    ai.commandBufferCount = 1;
    VkCommandBuffer cmd;
    vkAllocateCommandBuffers(device_, &ai, &cmd);
    recordCommandBuffer(cmd, imageIndex);

    VkPipelineStageFlags wait = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo si{};
    si.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    si.waitSemaphoreCount = 1;
    si.pWaitSemaphores = &acquireSem_;
    si.pWaitDstStageMask = &wait;
    si.commandBufferCount = 1;
    si.pCommandBuffers = &cmd;
    si.signalSemaphoreCount = 1;
    si.pSignalSemaphores = &renderSem_;
    vkQueueSubmit(queue_, 1, &si, inFlight_);

    VkPresentInfoKHR pi{};
    pi.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    pi.waitSemaphoreCount = 1;
    pi.pWaitSemaphores = &renderSem_;
    pi.swapchainCount = 1;
    pi.pSwapchains = &swapchain_;
    pi.pImageIndices = &imageIndex;
    VkResult pres = vkQueuePresentKHR(queue_, &pi);
    if (pres == VK_ERROR_OUT_OF_DATE_KHR || pres == VK_SUBOPTIMAL_KHR)
      recreateSwapchain();

    vkQueueWaitIdle(queue_);
    vkFreeCommandBuffers(device_, cmdPool_, 1, &cmd);
  }

  void recreateSwapchain() {
    if (!device_) return;
    vkDeviceWaitIdle(device_);
    destroySwapchain();
    if (resizePending_) {
      extent_.width = pendingWidth_ ? pendingWidth_ : extent_.width;
      extent_.height = pendingHeight_ ? pendingHeight_ : extent_.height;
      resizePending_ = false;
    }
    createSwapchain();
    createFramebuffers();
  }

  void destroySwapchain() {
    for (auto fb : framebuffers_)
      vkDestroyFramebuffer(device_, fb, nullptr);
    framebuffers_.clear();
    for (auto v : views_)
      vkDestroyImageView(device_, v, nullptr);
    views_.clear();
    if (swapchain_) {
      vkDestroySwapchainKHR(device_, swapchain_, nullptr);
      swapchain_ = VK_NULL_HANDLE;
    }
  }

  void cleanup() {
    if (device_) {
      vkDeviceWaitIdle(device_);
      destroySwapchain();
      if (inFlight_) vkDestroyFence(device_, inFlight_, nullptr);
      if (acquireSem_) vkDestroySemaphore(device_, acquireSem_, nullptr);
      if (renderSem_) vkDestroySemaphore(device_, renderSem_, nullptr);
      if (cmdPool_) vkDestroyCommandPool(device_, cmdPool_, nullptr);
      if (pipeline_) vkDestroyPipeline(device_, pipeline_, nullptr);
      if (pipelineLayout_) vkDestroyPipelineLayout(device_, pipelineLayout_, nullptr);
      if (renderPass_) vkDestroyRenderPass(device_, renderPass_, nullptr);
      vkDestroyDevice(device_, nullptr);
      device_ = VK_NULL_HANDLE;
    }
    if (surface_ && instance_) vkDestroySurfaceKHR(instance_, surface_, nullptr);
    if (instance_) vkDestroyInstance(instance_, nullptr);
    instance_ = VK_NULL_HANDLE;
  }
};
