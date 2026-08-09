// (c) 2018-2024 Ricci Adams
// MIT License (or) 1-clause BSD License
//
// Based on logic presented in these articles:
//
// https://www.mikeash.com/pyblog/friday-qa-2012-02-03-ring-buffers-and-mirrored-memory-part-i.html
// https://www.mikeash.com/pyblog/friday-qa-2012-02-17-ring-buffers-and-mirrored-memory-part-ii.html
//

#include "HugRingBuffer.h"
#include <stdatomic.h>


struct HugRingBuffer {
    UInt8  *_bytes;
    CFIndex _capacity;
    CFIndex _tailIndex __attribute__((aligned(128)));
    CFIndex _headIndex __attribute__((aligned(128)));
    volatile atomic_int _fillCount __attribute__((aligned(128)));
};


static void sSafeCopy(void *dst, const void *src, size_t n)
{
    for (CFIndex i = 0; i < n; i++) {
        ((UInt8 *)dst)[i] = ((UInt8 *)src)[i];
    }
}


HugRingBuffer *HugRingBufferCreate(CFIndex capacity)
{
    // Round capacity up to nearest page size
    capacity = (CFIndex)round_page(capacity);
  
    NSInteger loopGuard = 128;
    vm_address_t addr1 = 0;
    vm_address_t addr2 = 0;

    while (loopGuard-- > 0) {
        kern_return_t result;

        addr1 = addr2 = 0;

        result = vm_allocate(mach_task_self(), &addr1, capacity * 2, VM_FLAGS_ANYWHERE);
        if (result != ERR_SUCCESS) continue;

        result = vm_deallocate(mach_task_self(), addr1 + capacity, capacity);
        if (result != ERR_SUCCESS) continue;
        
        addr2 = addr1 + capacity;
        vm_prot_t unused1, unused2;

        result = vm_remap(
            mach_task_self(), &addr2, capacity, 0, 0,
            mach_task_self(),  addr1,
            0, &unused1, &unused2, VM_INHERIT_DEFAULT
        );
            
        if (result != ERR_SUCCESS) {
            if (addr1) vm_deallocate(mach_task_self(), addr1, capacity);
            addr1 = addr2 = 0;

            continue;
        }
        
        if (addr2 != (addr1 + capacity)) {
            if (addr2) vm_deallocate(mach_task_self(), addr2, capacity);
            if (addr1) vm_deallocate(mach_task_self(), addr1, capacity);
            addr2 = addr1 = 0;

            continue;
        }

        // Mapped. Without this the loop runs all 128 iterations, and since addr1 and addr2 are
        // cleared at the top of each one, every mapping but the last is leaked.
        //
        break;
    }

    if (addr2 == (addr1 + capacity)) {
        HugRingBuffer *buffer = calloc(1, sizeof(HugRingBuffer));

        buffer->_bytes = (UInt8 *)addr1;
        buffer->_capacity = capacity;

        return buffer;
    }
    
    return NULL;
}


void HugRingBufferFree(HugRingBuffer *self)
{
    if (!self) return;

    vm_deallocate(mach_task_self(), (vm_address_t)self->_bytes, self->_capacity * 2);
    free(self);
}


void HugRingBufferConfirmReadAll(HugRingBuffer *self)
{
    if (!self) return;

    int32_t fillCount = self->_fillCount;
    if (!fillCount) return;

    if (HugRingBufferGetReadPtr(self, fillCount)) {
        HugRingBufferConfirmRead(self, fillCount);
    }
}


void *HugRingBufferGetReadPtr(HugRingBuffer *self, CFIndex neededLength)
{
    if (!self) return NULL;

    size_t availableLength = self->_fillCount;

    return availableLength >= neededLength ?
        self->_bytes + self->_tailIndex :
        NULL;
}


void HugRingBufferConfirmRead(HugRingBuffer *self, CFIndex length)
{
    if (!self) return;

    self->_tailIndex = (self->_tailIndex + length) % self->_capacity;
    atomic_fetch_add(&self->_fillCount, -length);
}


BOOL HugRingBufferRead( HugRingBuffer *self, void *buffer, CFIndex length)
{
    void *readPtr = HugRingBufferGetReadPtr(self, length);
    if (!readPtr) return NO;

    sSafeCopy(buffer, readPtr, length);

    HugRingBufferConfirmRead(self, length);

    return YES;
}


void *HugRingBufferGetWritePtr(HugRingBuffer *self, CFIndex neededLength)
{
    if (!self) return NULL;

    NSInteger availableLength = self->_capacity - self->_fillCount;
    
    return (availableLength >= neededLength) ?
        self->_bytes + self->_headIndex :
        NULL;
}


void HugRingBufferConfirmWrite(HugRingBuffer *self, CFIndex length)
{
    if (!self) return;

    self->_headIndex = (self->_headIndex + length) % self->_capacity;
    atomic_fetch_add(&self->_fillCount, length);
}


BOOL HugRingBufferWrite(HugRingBuffer *self, void *buffer, CFIndex length)
{
    void *writePtr = HugRingBufferGetWritePtr(self, length);
    if (!writePtr) return NO;

    sSafeCopy(writePtr, buffer, length);
    
    HugRingBufferConfirmWrite(self, length);

    return YES;
}


extern CFIndex HugRingBufferGetCapacity(HugRingBuffer *buffer)
{
    return buffer->_capacity;
}

