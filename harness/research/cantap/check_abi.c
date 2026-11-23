// The constants and layouts can.zig, isotp.zig and notify.zig write out by
// hand, held against the kernel headers Zig ships. Compile only:
//   zig cc -target aarch64-linux-musl -fsyntax-only check_abi.c
#include <stddef.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <linux/can.h>
#include <linux/can/raw.h>
#include <linux/can/isotp.h>
#include <linux/can/error.h>

_Static_assert(AF_CAN == 29, "AF_CAN");
_Static_assert(CAN_RAW == 1 && CAN_ISOTP == 6, "protocols");
_Static_assert(SOL_CAN_RAW == 101 && SOL_CAN_ISOTP == 106, "levels");
_Static_assert(CAN_RAW_FILTER == 1 && CAN_RAW_ERR_FILTER == 2 && CAN_RAW_FD_FRAMES == 5, "raw options");
_Static_assert(CAN_ISOTP_OPTS == 1 && CAN_ISOTP_TX_PADDING == 0x4, "isotp options");
_Static_assert(CAN_EFF_FLAG == 0x80000000U && CAN_RTR_FLAG == 0x40000000U && CAN_ERR_FLAG == 0x20000000U, "id flags");
_Static_assert(CAN_SFF_MASK == 0x7FFU && CAN_EFF_MASK == 0x1FFFFFFFU && CAN_ERR_MASK == 0x1FFFFFFFU, "id masks");
_Static_assert(CAN_ERR_BUSOFF == 0x40U && CAN_ERR_CRTL == 0x04U, "error classes");
_Static_assert(CAN_ERR_CRTL_RX_PASSIVE == 0x10 && CAN_ERR_CRTL_TX_PASSIVE == 0x20, "controller state");
_Static_assert(CAN_MTU == 16 && CANFD_MTU == 72, "MTUs");
_Static_assert(sizeof(struct can_frame) == 16 && offsetof(struct can_frame, data) == 8, "can_frame");
_Static_assert(sizeof(struct canfd_frame) == 72 && offsetof(struct canfd_frame, data) == 8, "canfd_frame");
_Static_assert(offsetof(struct canfd_frame, flags) == 5, "canfd_frame flags");
_Static_assert(sizeof(struct can_filter) == 8, "can_filter");
_Static_assert(sizeof(struct sockaddr_can) == 24, "sockaddr_can");
_Static_assert(offsetof(struct sockaddr_can, can_ifindex) == 4, "sockaddr_can ifindex");
_Static_assert(offsetof(struct sockaddr_can, can_addr.tp.rx_id) == 8, "sockaddr_can rx_id");
_Static_assert(offsetof(struct sockaddr_can, can_addr.tp.tx_id) == 12, "sockaddr_can tx_id");
_Static_assert(sizeof(struct can_isotp_options) == 12, "can_isotp_options");
_Static_assert(offsetof(struct can_isotp_options, txpad_content) == 9, "txpad_content");
_Static_assert(SIOCGIFINDEX == 0x8933 && IFNAMSIZ == 16, "SIOCGIFINDEX");
_Static_assert(offsetof(struct sockaddr_un, sun_path) == 2, "sockaddr_un");
