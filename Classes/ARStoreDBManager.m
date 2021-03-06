//
//  ARStoreDBManager.m
//  AipaiReconsitution
//
//  Created by Dean.Yang on 2017/7/3.
//  Copyright © 2017年 Dean.Yang. All rights reserved.
//

#import "ARStoreDBManager.h"
#import <objc/runtime.h>

static NSString *const CREATE_TABLE_SQL =
@"CREATE TABLE IF NOT EXISTS %@ ( \
id TEXT UNIQUE  NOT NULL, \
json TEXT  NOT NULL, \
createdTime TEXT NOT NULL, \
orderby TEXT \
)";

static NSString *const DEFAULT_TABLE = @"_DefaultTable";

static NSString *const DROP_TABLE_SQL = @"DROP TABLE %@";
static NSString *const INSERT_ITEM_SQL = @"INSERT INTO %@ (id, json, createdTime, orderby) VALUES(?, ?, ?)";

// 尝试替换如果id存在，否则插入
static NSString *const REPLACE_INTO_ITEM_SQL = @"REPLACE INTO %@ (id, json, createdTime, orderby) values (?, ?, ?, ?)";
static NSString *const UPDATE_ITEM_SQL = @"UPDATE %@ SET json=?,orderby=? WHERE id=?";
static NSString *const QUERY_ITEM_SQL = @"SELECT json, createdTime, orderby FROM %@ WHERE id = ? LIMIT 1";
static NSString *const SELECT_ALL_SQL = @"SELECT * FROM %@ %@";
static NSString *const SELECT_ALL_ORDERBY_SQL = @"SELECT * FROM %@ %@ ORDER BY orderby %@";
static NSString *const SELECT_PAGE_SQL = @"SELECT * FROM %@ %@ LIMIT %@ OFFSET %@";
static NSString *const SELECT_PAGE_ORDERBY_SQL = @"SELECT * FROM %@ %@ ORDER BY orderby %@ LIMIT %@ OFFSET %@";
static NSString *const SELECT_ID_SQL = @"SELECT * FROM %@ WHERE id = ?";
static NSString *const COUNT_ALL_SQL = @"SELECT COUNT(*) as num FROM %@";
static NSString *const CLEAR_ALL_SQL = @"DELETE FROM %@";
static NSString *const DELETE_ITEM_SQL = @"DELETE FROM %@ WHERE id = ?";
static NSString *const DELETE_ITEMS_SQL = @"DELETE FROM %@ WHERE id in ( %@ )";

static BOOL checkTableName(NSString *tableName) {
    if (tableName == nil || tableName.length == 0 || [tableName rangeOfString:@" "].location != NSNotFound) {
        NSLog(@"ERROR, table name: %@ format error.",tableName);
        return NO;
    }
    return YES;
}

#pragma mark - 自定义对象转JSON

static id getObjectInternal(id obj);
static NSDictionary *getObjectData(id obj);

static NSDictionary *getObjectData(id obj) {
    NSMutableDictionary *dic = [NSMutableDictionary dictionary];
    unsigned int propsCount;
    Class cls = [obj class];
    if ([NSStringFromClass(cls) isEqualToString:NSStringFromClass([NSObject class])]) {
        return dic;
    }
    while (cls) {
        //Ivar *ivars = class_copyIvarList(cls, &propsCount);
        objc_property_t *props = class_copyPropertyList(cls, &propsCount);
        for(int i = 0;i < propsCount; i++) {
            objc_property_t prop = props[i];
            //Ivar ivar = ivars[i];
            NSString *propName = [NSString stringWithUTF8String:property_getName(prop)];
            //NSString *ivarName = [NSString stringWithUTF8String:ivar_getName(ivar)];
            if ([propName isEqualToString:@"superclass"] ||
                [propName isEqualToString:@"debugDescription"] ||
                [propName isEqualToString:@"hash"] ||
                [propName isEqualToString:@"description"]) {
                continue;
            }
            id value = [obj valueForKey:propName];
            if ([NSStringFromClass([value class]) isEqualToString:@"NSConcreteValue"]) {
                continue;
            }
            if(value) {
                value = getObjectInternal(value);
                [dic setObject:value forKey:propName];
            }
        }
        free(props);
        cls = class_getSuperclass(cls);
        if ([NSStringFromClass(cls) isEqualToString:NSStringFromClass([NSObject class])]) {
            break;
        }
        propsCount = 0;
    }
    return dic;
}

static id getObjectInternal(id obj) {
    
    if ([obj isKindOfClass:[NSURL class]]) {
        return ((NSURL*)obj).absoluteString;
    }
    
    if([obj isKindOfClass:[NSString class]] || [obj isKindOfClass:[NSNumber class]] || [obj isKindOfClass:[NSNull class]]) {
        return obj;
    }
    
    if([obj isKindOfClass:[NSArray class]]) {
        NSArray *objarr = obj;
        NSMutableArray *arr = [NSMutableArray arrayWithCapacity:objarr.count];
        for(int i = 0; i < objarr.count; i++) {
            [arr setObject:getObjectInternal([objarr objectAtIndex:i]) atIndexedSubscript:i];
        }
        return arr;
    }
    
    if([obj isKindOfClass:[NSDictionary class]]) {
        NSDictionary *objdic = obj;
        NSMutableDictionary *dic = [NSMutableDictionary dictionaryWithCapacity:[objdic count]];
        for(NSString *key in objdic.allKeys) {
            [dic setObject:getObjectInternal([objdic objectForKey:key]) forKey:key];
        }
        return dic;
    }
    
    return getObjectData(obj);
}


#pragma mark -

@implementation ARStoreDBModel
@end

@interface ARStoreDBManager()
@property (nonatomic, strong) FMDatabaseQueue *dbQueue;
@end

@implementation ARStoreDBManager

- (void)dealloc {
    [_dbQueue close];
    _dbQueue = nil;
}

static ARStoreDBManager *_storeDBManager;
+ (instancetype)shareStoreDBManager {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _storeDBManager = [[ARStoreDBManager alloc] init];
    });
    return _storeDBManager;
}

+ (instancetype)allocWithZone:(struct _NSZone *)zone {
    if (_storeDBManager) {
        return _storeDBManager;
    }
    return [super allocWithZone:zone];
}

- (instancetype)init {
    if (self = [super init]) {
        NSString *path = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).lastObject stringByAppendingPathComponent:@"_database.db"];
        self.dbQueue = [FMDatabaseQueue databaseQueueWithPath:path];
    }
    return self;
}

#pragma mark - public

- (BOOL)storeWithKey:(NSString *)key object:(id)object {
    
    if (![self isTableExists:DEFAULT_TABLE]) {
        if (![self createTableWithName:DEFAULT_TABLE]) {
            return NO;
        }
    }
    
    if (object == nil) {
        return [self deleteWithTableName:DEFAULT_TABLE identity:key];
    } else {
        return [self replaceWithTableName:DEFAULT_TABLE identitiy:key object:object order:[NSNull null]];
    }
}

- (BOOL)setObjectWithKey:(NSString *)key object:(id)object identityKey:(NSString *)identityKey orderKey:(NSString *)orderkey {

    if (![self isTableExists:key]) {
        if (![self createTableWithName:key]) {
            return NO;
        }
    }
    
    if ([object isKindOfClass:[NSArray class]]) {
        
        NSArray *array = (NSArray *)object;
        if (array.count == 0) {
            return NO;
        }
        
        NSMutableArray *identityArray = [NSMutableArray arrayWithCapacity:array.count];
        NSMutableArray *orderArray = [NSMutableArray arrayWithCapacity:array.count];
        
        for (id obj in array) {
            NSString* identity = (NSString *)[obj valueForKeyPath:identityKey];
            [identityArray addObject:identity];
            
            if (orderkey) {
                NSString *order = (NSString *)[obj valueForKeyPath:orderkey];
                [orderArray addObject:order];
            }
            
        }
        
        if([self multiDeleteWithTableName:key identities:identityArray]) {
            return [self insertWithTableName:key objects:array identities:[identityArray copy] orders:[orderArray copy]];
        }
        
        return YES;
        
    } else if([object isKindOfClass:[NSDictionary class]]) {
        
        NSDictionary *dict = (NSDictionary *)object;
        NSArray *keys = dict.allKeys;
        if (keys.count == 0) {
            return NO;
        }
        
        if([self multiDeleteWithTableName:key identities:keys]) {
            NSMutableArray *values = [NSMutableArray array];
            NSMutableArray *orders = [NSMutableArray array];
            for (id key in keys) {
                id obj = dict[key];
                [values addObject:obj];
                if (orderkey) {
                    NSString *order = (NSString *)[obj valueForKeyPath:orderkey];
                    [orders addObject:order];
                }
            }
            return [self insertWithTableName:key objects:values identities:keys orders:orders];
        }
        
        return NO;
        
    } else {
        
        NSString* identity = (NSString *)[object valueForKeyPath:identityKey];
        if(identity == nil) {
            return NO;
        }
        
        NSString *order = [NSNull null];
        if(orderkey) {
            order = [object valueForKeyPath:orderkey];
        }
        
        return [self replaceWithTableName:key identitiy:identity object:object order:order];
    }
    
    return NO;
}

- (NSUInteger)objectCountWithKey:(NSString *)key {
    
    NSCAssert(checkTableName(key),@"[ARStoreDBManager]（查询行记录数量）表名不能为nil");
    
    FMResultSet *resultSet = [self selectCountWithTableName:key];
    if ([resultSet next]) {
        NSUInteger count = [resultSet longForColumnIndex:0];
        [resultSet close];
        return count;
    }
    
    return 0;
}

- (NSArray<ARStoreDBModel *> *)objectWithKey:(NSString *)key pageIndex:(NSInteger)pageIndex pageSize:(NSInteger)pageSize comparison:(NSComparisonResult)comparison {
    return [self objectWithKey:key pageIndex:pageIndex pageSize:pageSize comparison:comparison condition:nil];
}

- (NSArray<ARStoreDBModel *> *)objectWithKey:(NSString *)key pageIndex:(NSInteger)pageIndex pageSize:(NSInteger)pageSize comparison:(NSComparisonResult)comparison condition:(NSArray<NSString *> *)ids {
    NSCAssert(checkTableName(key),@"[ARStoreDBManager]（查询记录）表名不能为nil");
    
    @synchronized(self) {
        @autoreleasepool {
            FMResultSet *resultSet = nil;
            NSString *order = comparison == NSOrderedSame ? nil : (comparison == NSOrderedAscending ? @"ASC" : @"DESC");
            pageIndex = MAX(0, pageIndex);
            
            NSString *condition;
            if (ids.count) {
                condition = [NSString stringWithFormat:@"id in ('%@')",[ids componentsJoinedByString:@"','"]];
            }
            
            if ([self isTableExists:key]) {
                if (pageSize > 0) {
                    if (order == nil) {
                        resultSet = [self selectWithTableName:key size:pageSize offset:pageIndex * pageSize condition:condition];
                    } else {
                        resultSet = [self selectWithTableName:key size:pageSize offset:pageIndex * pageSize order:order condition:condition];
                    }
                } else {
                    if (order == nil) {
                        resultSet = [self selectWithTableName:key condition:condition];
                    } else {
                        resultSet = [self selectWithTableName:key order:order condition:condition];
                    }
                }
            } else {
                resultSet = [self selectWithTableName:DEFAULT_TABLE whereId:key];
            }
            
            if (resultSet) {
                NSMutableArray *array = [NSMutableArray array];
                while ([resultSet next]) {
                    ARStoreDBModel *item = [self analysisResultRow:resultSet];
                    [array addObject:item];
                }
                
                [resultSet close];
                
                return [array copy];
            }
        }
    }
    return nil;
}

- (ARStoreDBModel *)objectWithKey:(NSString *)key identity:(NSString *)identity {
    NSCAssert(checkTableName(key),@"[ARStoreDBManager]（查询某行记录）表名不能为nil");
    
    @synchronized(self) {
        @autoreleasepool {
            FMResultSet *resultSet = nil;
            if ([self isTableExists:key]) {
                NSCAssert((identity.length),@"[ARStoreDBManager]（查询某行记录）唯一标识不能为nil");
                resultSet = [self selectWithTableName:key whereId:identity];
                
            } else {
                resultSet = [self selectWithTableName:DEFAULT_TABLE whereId:key];
            }
            
            if (resultSet) {
                ARStoreDBModel *item;
                while ([resultSet next]) {
                    item = [self analysisResultRow:resultSet];
                    break;
                }
                [resultSet close];
                return item;
            }
        }
    }
    
    return nil;
}

- (ARStoreDBModel *)analysisResultRow:(FMResultSet *)resultSet {
    ARStoreDBModel *item = [[ARStoreDBModel alloc] init];
    item.identity = [resultSet stringForColumn:@"id"];
    
    NSString *json = [resultSet stringForColumn:@"json"];
    NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
    
    NSError *error = nil;
    id object = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingAllowFragments error:&error];
    
    if (error) {
        item.object = json;
    } else {
        item.object = object;
    }
    
    item.createdTime = [resultSet dateForColumn:@"createdTime"];
    item.orderby = [resultSet stringForColumn:@"orderby"];
    return item;
}

- (BOOL)removeWithKey:(NSString *)key identities:(NSArray<__kindof NSString *> *)identities {
    NSCAssert(checkTableName(key),@"[ARStoreDBManager]（删除记录）表名不能为nil");
    
    if (identities.count == 0) {
        return [self clearTable:key];
    } else {
        if (identities.count > 1) {
            return [self multiDeleteWithTableName:key identities:identities];
        } else {
            return [self deleteWithTableName:key identity:[identities firstObject]];
        }
    }
    
    return NO;
}

#pragma mark - private

- (BOOL)createTableWithName:(NSString *)tableName {
    NSCAssert(checkTableName(tableName),@"[ARStoreDBManager]（创建表）表名不能为nil");
    
    NSString * sql = [NSString stringWithFormat:CREATE_TABLE_SQL, tableName];
    __block BOOL result;
    @synchronized(self) {
        [_dbQueue inDatabase:^(FMDatabase *db) {
            result = [db executeUpdate:sql];
        }];
    }
    
    return result;
}

- (BOOL)isTableExists:(NSString *)tableName {
    NSCAssert(checkTableName(tableName),@"[ARStoreDBManager]（检测表是否存在）表名不能为nil");
    
    __block BOOL result;
    @synchronized(self) {
        [_dbQueue inDatabase:^(FMDatabase *db) {
            result = [db tableExists:tableName];
        }];
    }
    return result;
}

- (id)generatedJsonWithObject:(id)object {
    
    if ([object isKindOfClass:[NSString class]]) {
        return [NSString stringWithFormat:@"\"%@\"",object];
    } else if ([object isKindOfClass:[NSNumber class]]) {
        return object;
    }
    
    if ([object isKindOfClass:[NSArray class]]) {
        NSMutableArray *jsonArray = [NSMutableArray new];
        for (id subObj in object) {
            id subJson = [self generatedJsonWithObject:subObj];
            [jsonArray addObject:subJson];
        }
        
        return [jsonArray copy];
    } else if ([object isKindOfClass:[NSDictionary class]]) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    
    id obj = getObjectData(object);
    NSData *data = [NSJSONSerialization dataWithJSONObject:obj options:0 error:nil];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

#pragma mark - insert

- (BOOL)insertWithTableName:(NSString *)tableName objects:(NSArray<id> *)objects identities:(NSArray *)identities orders:(NSArray *)orders {
    
    if (objects.count != identities.count || identities.count == 0) {
        return NO;
    }
    
    NSDate *createdTime = [NSDate date];
    NSString *sql = [NSString stringWithFormat:REPLACE_INTO_ITEM_SQL, tableName];
    
    id jsonObject = [self generatedJsonWithObject:objects];
    
    __block BOOL result;
    @synchronized(self) {
        [_dbQueue inTransaction:^(FMDatabase *db, BOOL *rollback) {
            if ([jsonObject isKindOfClass:[NSArray class]]) {
                NSArray *jsonArray = (NSArray *)jsonObject;
                for (int i = 0; i < jsonArray.count; i++) {
                    
                    NSString *order = [NSNull null];
                    if (orders.count > i) {
                        order = orders[i];
                    }
                    
                    result = [db executeUpdate:sql, identities[i], jsonArray[i], createdTime, order];
                    if (!result) {
                        *rollback = YES;
                        return;
                    }
                }
            } else {
                result = [db executeUpdate:sql, [identities firstObject], jsonObject, createdTime];
            }
        }];
    }
    
    return result;
}

#pragma mark - delete

- (BOOL)deleteWithTableName:(NSString *)tableName identity:(NSString *)identity {
    
    NSString *sql = [NSString stringWithFormat:DELETE_ITEM_SQL, tableName];
    
    __block BOOL result;
    @synchronized(self) {
        [_dbQueue inDatabase:^(FMDatabase *db) {
            result = [db executeUpdate:sql,identity];
        }];
    }
    
    return result;
}

- (BOOL)multiDeleteWithTableName:(NSString *)tableName identities:(NSArray<NSString *> *)identities {
    
    NSMutableArray *identityArray = [NSMutableArray arrayWithCapacity:identities.count];
    for (NSString *orign in identities) {
        [identityArray addObject:[NSString stringWithFormat:@"'%@'",orign]];
    }
    
    NSString *sql = [NSString stringWithFormat:DELETE_ITEMS_SQL, tableName,[identityArray componentsJoinedByString:@","]];
    
    __block BOOL result;
    @synchronized(self) {
        [_dbQueue inDatabase:^(FMDatabase *db) {
            result = [db executeUpdate:sql];
        }];
    }
    
    return result;
}

- (BOOL)clearTable:(NSString *)tableName {
    
    NSString * sql = [NSString stringWithFormat:CLEAR_ALL_SQL, tableName];
    __block BOOL result;
    @synchronized(self) {
        [_dbQueue inDatabase:^(FMDatabase *db) {
            result = [db executeUpdate:sql];
        }];
    }
    
    return result;
}

#pragma mark - select

- (FMResultSet *)selectWithTableName:(NSString *)tableName condition:(NSString *)condition {
    
    NSString *where = condition ? [NSString stringWithFormat:@"where %@",condition] : @"";
    NSString *sql = [NSString stringWithFormat:SELECT_ALL_SQL, tableName, where];
    
    __block FMResultSet *resultSet;
    @synchronized(self) {
        [_dbQueue inDatabase:^(FMDatabase *db) {
            resultSet = [db executeQuery:sql];
        }];
    }
    
    return resultSet;
}

- (FMResultSet *)selectWithTableName:(NSString *)tableName order:(NSString *)order condition:(NSString *)condition {
    
    NSString *where = condition ? [NSString stringWithFormat:@"where %@",condition] : @"";
    NSString *sql = [NSString stringWithFormat:SELECT_ALL_ORDERBY_SQL, tableName, where, order];
    
    __block FMResultSet *resultSet;
    @synchronized(self) {
        [_dbQueue inDatabase:^(FMDatabase *db) {
            resultSet = [db executeQuery:sql];
        }];
    }
    
    return resultSet;
}

- (FMResultSet *)selectWithTableName:(NSString *)tableName
                                size:(NSInteger)size
                              offset:(NSUInteger)offset
                            condition:(NSString *)condition {
    
    NSString *where = condition ? [NSString stringWithFormat:@"where %@",condition] : @"";
    NSString *sql = [NSString stringWithFormat:SELECT_PAGE_SQL, tableName, where, @(size), @(offset)];
    
    __block FMResultSet *resultSet;
    @synchronized(self) {
        [_dbQueue inDatabase:^(FMDatabase *db) {
            resultSet = [db executeQuery:sql];
        }];
    }
    
    return resultSet;
}

- (FMResultSet *)selectWithTableName:(NSString *)tableName
                                size:(NSInteger)size
                              offset:(NSUInteger)offset
                               order:(NSString *)order
                           condition:(NSString *)condition {
    
    NSString *where = condition ? [NSString stringWithFormat:@"where %@",condition] : @"";
    NSString *sql = [NSString stringWithFormat:SELECT_PAGE_ORDERBY_SQL, tableName, where, order, @(size), @(offset)];
    
    __block FMResultSet *resultSet;
    @synchronized(self) {
        [_dbQueue inDatabase:^(FMDatabase *db) {
            resultSet = [db executeQuery:sql];
        }];
    }
    
    return resultSet;
}

- (FMResultSet *)selectWithTableName:(NSString *)tableName whereId:(NSString *)whereId {
    
    NSString *sql = [NSString stringWithFormat:SELECT_ID_SQL, tableName];
    
    __block FMResultSet *resultSet;
    @synchronized(self) {
        [_dbQueue inDatabase:^(FMDatabase *db) {
            resultSet = [db executeQuery:sql,whereId];
        }];
    }
    
    return resultSet;
}

- (FMResultSet *)selectCountWithTableName:(NSString *)tableName {
    
    NSString *sql = [NSString stringWithFormat:COUNT_ALL_SQL, tableName];
    
    __block FMResultSet *resultSet;
    @synchronized(self) {
        [_dbQueue inDatabase:^(FMDatabase *db) {
            resultSet = [db executeQuery:sql];
        }];
    }
    
    return resultSet;
}

#pragma mark - update / insert into

- (BOOL)replaceWithTableName:(NSString *)tableName identitiy:(NSString *)identity object:(id)object order:(NSString *)order {
    
    NSDate *createdTime = [NSDate date];
    NSString *sql = [NSString stringWithFormat:REPLACE_INTO_ITEM_SQL, tableName];
    
    id jsonObject = [self generatedJsonWithObject:object];
    if ([jsonObject isKindOfClass:[NSArray class]]) {
        jsonObject = [NSString stringWithFormat:@"[%@]",[((NSArray *)jsonObject) componentsJoinedByString:@","]];
    }
    
    
    __block BOOL result;
    @synchronized(self) {
        [_dbQueue inDatabase:^(FMDatabase *db) {
            result = [db executeUpdate:sql,identity,jsonObject,createdTime, order];
        }];
    }
    
    return result;
}



@end

