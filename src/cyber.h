// Copyright (c) 2023 Cyber (See LICENSE)
#include <string.h>
#include <stdint.h>

#define bool _Bool

typedef struct CyUserVM CyUserVM;
typedef struct CyModule CyModule;
typedef uint64_t CyValue;

const uint32_t CY_NullId = UINT32_MAX;

typedef enum {
    CY_Success = 0,
    CY_ErrorToken,
    CY_ErrorParse,
    CY_ErrorCompile,
    CY_ErrorPanic,
    CY_ErrorUnknown,
} CyResultCode;

// Null terminated string, but also includes a length.
typedef struct CStr {
    char* charz;
    size_t len;
} CStr;
#define cstr(X) (CStr){ X, strlen(X) }

typedef CyValue (*CyFunc)(CyUserVM* vm, CyValue* args, uint8_t nargs);
typedef void (*CyLoadModuleFunc)(CyUserVM* vm, CyModule* mod);

// VM.
CyUserVM* cyVmCreate();
void cyVmDestroy(CyUserVM* vm);
CyResultCode cyVmEval(CyUserVM* vm, CStr src, CyValue* outVal);
CStr cyVmGetLastErrorReport(CyUserVM* vm);
void cyVmRelease(CyUserVM* vm, CyValue val);

// Modules.
void cyVmAddModuleLoader(CyUserVM* vm, CStr name, CyLoadModuleFunc func);
void cyVmSetModuleFunc(CyUserVM* vm, CyModule* mod, CStr name, uint32_t numParams, CyFunc func);

// Intended to be used to manage accessible buffers when embedding WASM.
void* cyVmAlloc(CyUserVM* vm, size_t size);
void cyVmFree(CyUserVM* vm, void* ptr, size_t len);

// Initialize values.
CyValue cyValueNone();
CyValue cyValueTrue();
CyValue cyValueFalse();
CyValue cyValueNumber(double n);

// Values to C types.
double cyValueAsDouble(CyValue val);