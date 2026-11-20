#pragma once
#import <Foundation/Foundation.h>
/* Optional UI-only extension; failure to hook never blocks native opens. */
FOUNDATION_EXPORT BOOL PXWindowMemoryInstall(Class panel, Class bridge, Class hostController);
