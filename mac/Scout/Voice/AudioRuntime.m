#import "AudioRuntime.h"
#import <objc/runtime.h>

const void * _Nullable ScoutClassOf(id object) {
    return (__bridge const void *)object_getClass(object);
}

IMP _Nullable ScoutMethod(const void *classPointer, SEL selector) {
    return class_getMethodImplementation((__bridge Class)classPointer, selector);
}
