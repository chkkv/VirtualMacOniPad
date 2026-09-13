#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Adds the Virtio socket endpoint consumed by macOS's built-in
// AppleQEMUGuestAgent. No network connection or guest credentials are used.
BOOL VZGuestToolsConfigureDevice(id configuration);
void VZGuestToolsAttachToVirtualMachine(id virtualMachine);
void VZGuestToolsStartProvisioning(NSString *bundlePath,
                                   BOOL guestToolsEnabled,
                                   BOOL openGLAccelerationEnabled,
                                   BOOL pencilSupportEnabled,
                                   BOOL removalPending);
void VZGuestToolsReset(void);

// Updates the virtual Mac's NVRAM before its platform configuration is used.
BOOL VZGuestToolsConfigureBootArguments(id auxiliaryStorage,
                                        BOOL guestAgentEnabled,
                                        BOOL openGLAccelerationEnabled,
                                        NSError **error);

// Records that a bundle's disk image was enlarged on the host. The guest agent
// grows the APFS container to fill the new space on the next start and consumes
// the marker. It is a no-op when the guest agent is unavailable.
void VZGuestToolsRequestDiskExpansion(NSString *bundlePath);

NS_ASSUME_NONNULL_END
