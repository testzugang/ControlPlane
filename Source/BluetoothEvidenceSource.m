//
//  BluetoothEvidenceSource.m
//  ControlPlane
//
//  Created by David Symonds on 29/03/07.
//  Modified by Dustin Rue 8/5/2011.
//

#import "BluetoothEvidenceSource.h"
#import "DB.h"
#import "DSLogger.h"

#define EXPIRY_INTERVAL		((NSTimeInterval) 60)


@interface BluetoothEvidenceSource (Private)

- (void)registerForNotifications:(NSTimer *)timer;
- (void)deviceConnected:(IOBluetoothUserNotification *)notification device:(IOBluetoothDevice *)device;
- (void)deviceDisconnected:(IOBluetoothUserNotification *)notification device:(IOBluetoothDevice *)device;

@end

@implementation BluetoothEvidenceSource

@synthesize kIOErrorSet;
@synthesize inquiryStatus;
@synthesize registeredForNotifications;

- (id)init
{
	if (!(self = [super init]))
		return nil;

	lock = [[NSLock alloc] init];
	devices = [[NSMutableArray alloc] init];
    devicesRegisteredForDisconnectNotices = [[NSMutableArray alloc] init];

    [self setKIOErrorSet:FALSE];
    
    timerCounter = 0;

    
    [self setRegisteredForNotifications:FALSE];

	return self;
}



- (void)dealloc
{
#ifdef DEBUG_MODE
    DSLog(@"in dealloc");
#endif
	[lock release];
	[devices release];
	[inq release];

	[super dealloc];
}

- (void)start
{

#ifdef DEBUG_MODE
    DSLog(@"In bluetooth start");
#endif
    
    // need to register for bluetooth connect notifications, but we need to delay it
    // until everything is loaded or we'll dead lock, not sure why
    
#ifdef DEBUG_MODE
    DSLog(@"setting 5 second timer to register for bluetooth connection notifications");
#endif
    registerForNotificationsTimer = [NSTimer scheduledTimerWithTimeInterval:(NSTimeInterval) 5 target:self selector:@selector(registerForNotifications:) userInfo:nil repeats:NO]; 

    // we now mark the evidence source as running
	running = YES;
    
	
}

- (void)stop
{
#ifdef DEBUG_MODE
    DSLog(@"In stop");
#endif

	if (![self registeredForNotifications])
		return;
    
    
    [self unregisterForConnectionNotifications];
    
    // we registered for disconnect notifications, unregister now
    for (IOBluetoothUserNotification *currentDevice in devicesRegisteredForDisconnectNotices) {
        [currentDevice unregister];
    }

	[lock lock];
	[devices removeAllObjects];
	[self setDataCollected:NO];
	[lock unlock];
    
    // mark evidence source as not running
    running = NO;

	
}

#pragma mark Device Connect Notification Control



- (void) registerForConnectionNotifications {
    
    if (![self registeredForNotifications]) {
#ifdef DEBUG_MODE
        DSLog(@"registering for connection notifications");
#endif
        notf = [IOBluetoothDevice registerForConnectNotifications:self
                                                         selector:@selector(deviceConnected:device:)];
        [self setRegisteredForNotifications:TRUE];
    }
    
}

- (void) unregisterForConnectionNotifications {
    
  //  if ([self registeredForNotifications]) {
#ifdef DEBUG_MODE
        DSLog(@"unregistering for connection notifications");
#endif
        [notf unregister];
        notf = nil;

        [self setRegisteredForNotifications:FALSE];
  //  }
}



#pragma mark -

- (void)registerForNotifications:(NSTimer *)timer {
    
#ifdef DEBUG_MODE
    DSLog(@"registering for notifications");
#endif
    
    [self registerForConnectionNotifications];
    
}


// Returns a string (set to auto-release), or nil.
+ (NSString *)vendorByMAC:(NSString *)mac
{
	NSDictionary *ouiDb = [DB sharedOUIDB];
    
#ifdef DEBUG_MODE 
    //DSLog(@"ouiDB looks like %@", ouiDb);
#endif
    
    
	NSString *oui = [[mac substringToIndex:8] uppercaseString];
#ifdef DEBUG_MODE
    DSLog(@"attempting to get vendor info for mac %@", oui);
#endif
	NSString *name = [ouiDb valueForKey:oui];
    
#ifdef DEBUG_MODE
    DSLog(@"converted %@ to %@", mac, name);
#endif

	return name;
}



//- (void)doUpdate
//{
    

//	// Silly Apple made the IOBluetooth framework non-thread-safe, and require all
//	// Bluetooth calls to be made from the main thread
//	[self performSelectorOnMainThread:@selector(doUpdateForReal) withObject:nil waitUntilDone:YES];
//}

- (NSString *)name
{
	return @"Bluetooth";
}

- (BOOL)doesRuleMatch:(NSDictionary *)rule
{
	BOOL match = NO;
#ifdef DEBUG_MODE
    DSLog(@"dev dictionary looks like %@",devices);
#endif
    
    // TODO: fix this issue, we shouldn't be here if inquiryStatus
    // and registeredForNotifications are both false.  This indicates
    // we're not supposed to be running but for some reason 
    // ControlPlane will continue to fire the inquiryDidComplete selector
    // until bluetooth is disabled, the program is closed or the computer
    // goes through a sleep/wake cycle
    if (![self registeredForNotifications]) 
        return FALSE; 

	[lock lock];
	NSEnumerator *en = [devices objectEnumerator];
	NSDictionary *dev;
	NSString *mac = [rule objectForKey:@"parameter"];
	while ((dev = [en nextObject])) {
		if ([[dev valueForKey:@"mac"] isEqualToString:mac]) {
			match = YES;
			break;
		}
	}
	[lock unlock];

	return match;
}

- (NSString *)getSuggestionLeadText:(NSString *)type
{
	return NSLocalizedString(@"If connected", @"In rule-adding dialog");
}

- (NSArray *)getSuggestions
{
	NSMutableArray *arr = [NSMutableArray arrayWithCapacity:[devices count]];

	[lock lock];
	NSEnumerator *en = [devices objectEnumerator];
	NSDictionary *dev;
#ifdef DEBUG_MODE
    DSLog(@"dev dictionary looks like %@",devices);
#endif
	while ((dev = [en nextObject])) {
		NSString *name = [dev valueForKey:@"device_name"];
		if (!name)
			name = NSLocalizedString(@"(Unnamed device)", @"String for unnamed devices");
		NSString *vendor = [dev valueForKey:@"vendor_name"];
		if (!vendor)
			vendor = [dev valueForKey:@"mac"];

		NSString *desc = [NSString stringWithFormat:@"%@ [%@]", name, vendor];
		[arr addObject:[NSDictionary dictionaryWithObjectsAndKeys:
			@"Bluetooth", @"type",
			[dev valueForKey:@"mac"], @"parameter",
			desc, @"description", nil]];
	}
	[lock unlock];

	return arr;
}


#pragma mark Paired device notifications

- (void)deviceConnected:(IOBluetoothUserNotification *)notification device:(IOBluetoothDevice *)device
{
    // we're being notified that a device has connected
#ifdef DEBUG_MODE
	DSLog(@"Got notified of '%@' connecting!, %@", [device name], [device getAddressString]);
#endif
    
    // tell the bluetooth API we want to know when this device goes away
	[devicesRegisteredForDisconnectNotices addObject:[device registerForDisconnectNotification:self selector:@selector(deviceDisconnected:device:)]];
   // [devices addObject:device];
    [self deviceInquiryDeviceFound:nil device:device];
}

- (void)deviceDisconnected:(IOBluetoothUserNotification *)notification device:(IOBluetoothDevice *)device
{
#ifdef DEBUG_MODE
	DSLog(@"Got notified of '%@' disconnecting!", [device name]);
#endif
    
    
    
	[lock lock];
	NSEnumerator *en = [devices objectEnumerator];
	NSMutableDictionary *dev;
	unsigned int index = 0;
    
    
    
	while ((dev = [en nextObject])) {
		if ([[dev valueForKey:@"mac"] isEqualToString:[device getAddressString]])
			break;
		++index;
	}
    
    
	if (dev)
		[devices removeObjectAtIndex:index];
    
    
	[lock unlock];
}

- (void)deviceInquiryDeviceFound:(IOBluetoothDeviceInquiry *)sender
                          device:(IOBluetoothDevice *)device
{
	
#ifdef DEBUG_MODE
    DSLog(@"in deviceInquiryDeviceFound");
#endif
    
    
    
    // going to add the found device to a dictionary
    // that we later attempt to match against (a rule)
    [lock lock];
	NSDate *expires = [NSDate dateWithTimeIntervalSinceNow:EXPIRY_INTERVAL];
	if (!sender)	// paired device; hang onto it indefinitely
		expires = [NSDate distantFuture];
	NSEnumerator *en = [devices objectEnumerator];
	NSMutableDictionary *dev;
	while ((dev = [en nextObject])) {
		if ([[dev valueForKey:@"mac"] isEqualToString:[device getAddressString]])
			break;
	}
	if (dev) {
		// Update
		if (![dev valueForKey:@"device_name"])
			[dev setValue:[device name] forKey:@"device_name"];
		[dev setValue:expires forKey:@"expires"];
	} else {
		// Insert
		NSString *mac = [[[device getAddressString] copy] autorelease];
		NSString *vendor = [[self class] vendorByMAC:mac];
        
		dev = [NSMutableDictionary dictionary];
		[dev setValue:mac forKey:@"mac"];
		if ([device name])
			[dev setValue:[[[device name] copy] autorelease] forKey:@"device_name"];
		if (vendor)
			[dev setValue:vendor forKey:@"vendor_name"];
		[dev setValue:expires forKey:@"expires"];
        
		[devices addObject:dev];
	}
    
	[self setDataCollected:[devices count] > 0];
	[lock unlock];
}


@end