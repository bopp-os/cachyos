# Configuration
registry := "ghcr.io"
user := "ripps818"
image_name := "cachyos-boppos-bootc"
full_image := registry + "/" + user + "/" + image_name

# Default action
default:
    @just --list

# Build the container image.
# Accepts an optional architecture (v3, v4, znver4).
build arch='v3':
    @echo "Building {{full_image}}:{{arch}} for TARGET_CPU_MARCH={{arch}}..."
    sudo podman build \
        --network=host \
        --build-arg TARGET_CPU_MARCH={{arch}} \
        --build-arg BASE_IMAGE_TAG=$(if [ "{{arch}}" = "znver4" ]; then echo "v4"; else echo "{{arch}}"; fi) \
        -t "{{full_image}}:{{arch}}" \
        .

# Push the built image(s) to the container registry.
push arch='v3':
    @echo "Pushing {{full_image}}:{{arch}}..."
    sudo podman push \
        "{{full_image}}:{{arch}}"

switch tag='v3':
    @echo "Switching system to {{full_image}}:{{tag}}..."
    sudo bootc switch \
        "{{full_image}}:{{tag}}"

# Manually apply kernel arguments to the currently running system for local testing
apply-local-kargs:
    @echo "Applying kernel arguments locally..."
    sudo ostree admin kargs edit-in-place \
        --append-if-missing="amd_pstate=active" \
        --append-if-missing="amdgpu.ppfeaturemask=0xffffffff" \
        --append-if-missing="split_lock_detect=off" \
        --append-if-missing="nowatchdog" \
        --append-if-missing="nmi_watchdog=0" \
        --append-if-missing="mitigations=off" \
        --append-if-missing="sysrq_always_enabled=1" \
        --append-if-missing="usbcore.autosuspend=-1" \
        --append-if-missing="iommu=pt" \
        --append-if-missing="preempt=full" \
        --append-if-missing="amdgpu.gpu_recovery=1" \
        --append-if-missing="transparent_hugepage=madvise" \
        --append-if-missing="transparent_hugepage.defrag=defer+madvise"
    @echo "Kernel arguments updated. Please reboot to apply changes."
