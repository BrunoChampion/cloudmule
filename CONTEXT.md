# cloudmule

cloudmule rents one Hetzner server by the hour, shared by all of a user's projects, so their own computer only edits.

## Language

**Shared server**:
The single rented server every project of the user works on; it exists only while someone uses it.
_Avoid_: instance, VM, machine

**Lease**:
A project's (or target's) claim on the shared server; the server is deleted only when no lease remains.
_Avoid_: lock, session

**Workspace**:
The snapshot of the whole shared server's disk, saved when it is deleted and restored when it is created again; only the latest is kept.
_Avoid_: image, backup

**Disk floor**:
The minimum disk size a server must have to restore the workspace: the disk size of the server the workspace was saved from.
_Avoid_: workspace minimum disk, snapshot lock-in
