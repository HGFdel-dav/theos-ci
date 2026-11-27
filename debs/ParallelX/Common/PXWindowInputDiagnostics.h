#pragma once
#import <UIKit/UIKit.h>
#include <stdint.h>
/* SpringBoard-only, diagnostics setting respected. No remote input ACK is
 * claimed: the observation ends at host UIWindow dispatch. */
BOOL PXWindowInputDiagnosticsInstall(Class bridgeClass);
void PXWindowInputDiagnosticsBind(id bridge,UIView *canvas,NSString *bundle,uint64_t serial,double openedAt);
void PXWindowInputDiagnosticsObserve(id bridge,unsigned stage);
void PXWindowInputDiagnosticsLinkTransaction(id bridge,uint64_t token);
void PXWindowInputDiagnosticsClose(id bridge);
