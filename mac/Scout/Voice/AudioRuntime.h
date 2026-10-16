#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

const void * _Nullable ScoutClassOf(id object);
IMP _Nullable ScoutMethod(const void *classPointer, SEL selector);

NS_ASSUME_NONNULL_END
