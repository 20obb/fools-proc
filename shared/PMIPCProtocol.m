#import "PMIPCProtocol.h"

NSUInteger const PMIPCProtocolDefaultMaxLineBytes = 8192;

@implementation PMIPCProtocol

+ (nullable NSData *)lineDataFromJSONObject:(id)object error:(NSError **)error {
    if (!object) {
        if (error) {
            *error = [NSError errorWithDomain:@"PMIPCProtocol" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Object cannot be nil"}];
        }
        return nil;
    }

    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:object options:0 error:error];
    if (!jsonData) {
        return nil;
    }

    NSMutableData *lineData = [jsonData mutableCopy];
    const char newline = '\n';
    [lineData appendBytes:&newline length:1];
    return [lineData copy];
}

+ (nullable NSDictionary *)dictionaryFromLineData:(NSData *)lineData error:(NSError **)error {
    if (!lineData || lineData.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"PMIPCProtocol" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Line data is empty"}];
        }
        return nil;
    }

    id object = [NSJSONSerialization JSONObjectWithData:lineData options:NSJSONReadingMutableContainers error:error];
    if (![object isKindOfClass:[NSDictionary class]]) {
        if (error && !*error) {
            *error = [NSError errorWithDomain:@"PMIPCProtocol" code:3 userInfo:@{NSLocalizedDescriptionKey: @"Line is not a dictionary"}];
        }
        return nil;
    }

    return (NSDictionary *)object;
}

+ (NSDictionary *)okResponseForCommand:(NSString *)command payload:(nullable NSDictionary *)payload {
    NSMutableDictionary *response = [NSMutableDictionary dictionary];
    response[@"type"] = @"response";
    response[@"ok"] = @YES;
    if (command.length > 0) {
        response[@"command"] = command;
    }
    if (payload.count > 0) {
        response[@"data"] = payload;
    }
    response[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    return response;
}

+ (NSDictionary *)errorResponseForCommand:(nullable NSString *)command code:(NSString *)code message:(NSString *)message {
    NSMutableDictionary *response = [NSMutableDictionary dictionary];
    response[@"type"] = @"response";
    response[@"ok"] = @NO;
    if (command.length > 0) {
        response[@"command"] = command;
    }
    response[@"error_code"] = code.length > 0 ? code : @"unknown_error";
    response[@"error"] = message.length > 0 ? message : @"Unknown error";
    response[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    return response;
}

@end
