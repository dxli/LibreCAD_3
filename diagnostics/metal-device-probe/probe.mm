// Isolated diagnostics only. No adapter classification or acceptance policy.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <IOKit/IOKitLib.h>
#include <objc/message.h>
#include <objc/runtime.h>
#include <QDateTime>
#include <QGuiApplication>
#include <QJsonArray>
#include <QJsonDocument>
#include <QJsonObject>
#include <QLibraryInfo>
#include <QSaveFile>
#include <QSysInfo>
#include <rhi/qrhi_platform.h>
#include <cstdint>
#include <memory>
#include <stdexcept>

static QString text(const char* value) {
    return value ? QString::fromUtf8(value).left(1024) : QString();
}
static QString text(NSString* value) {
    return value ? text([value UTF8String]) : QString();
}
static QString number(std::uint64_t value) { return QString::number(qulonglong(value)); }
struct Report {
    QString path;
    QJsonObject data{{"evidence_kind", "selected-metal-device-diagnostic"},
                     {"acceptance_claim", false}, {"qt_version", qVersion()},
                     {"architecture", QSysInfo::currentCpuArchitecture()},
                     {"created_utc", QDateTime::currentDateTimeUtc().toString(Qt::ISODate)}};
    void save(const QString& stage) {
        data["stage"] = stage;
        QSaveFile file(path);
        const auto bytes = QJsonDocument(data).toJson();
        if (!file.open(QIODevice::WriteOnly) || file.write(bytes) != bytes.size() || !file.commit())
            throw std::runtime_error("Could not save diagnostic stage");
    }
};
static QJsonObject selectors(id device) {
    const SEL selector = sel_registerName("registryID");
    return {{"static_class_responds", bool(class_respondsToSelector(object_getClass(device), selector))},
            {"instance_responds", bool([device respondsToSelector:selector])}};
}
static QJsonArray classes(id device) {
    QJsonArray result;
    for (Class cls = object_getClass(device); cls && result.size() < 16; cls = class_getSuperclass(cls))
        result.append(QJsonObject{{"class", text(class_getName(cls))}, {"image", text(class_getImageName(cls))}});
    return result;
}
static QJsonObject registry(std::uint64_t requested) {
    QJsonObject result{{"requested_id", number(requested)}};
    if (!requested) return result;
    auto matching = IORegistryEntryIDMatching(requested);
    result["matching_created"] = bool(matching);
    if (!matching) return result;
    const io_service_t entry = IOServiceGetMatchingService(kIOMainPortDefault, matching); // consumes matching
    result["entry_found"] = bool(entry);
    if (!entry) return result;
    std::uint64_t actual = 0;
    io_name_t name = {};
    io_string_t path = {};
    result["id_status"] = int(IORegistryEntryGetRegistryEntryID(entry, &actual));
    result["actual_id"] = number(actual);
    result["class_status"] = int(IOObjectGetClass(entry, name));
    result["class"] = text(name);
    result["path_status"] = int(IORegistryEntryGetPath(entry, kIOServicePlane, path));
    result["path"] = text(path);
    result["conforms_apple_paravirt"] = bool(IOObjectConformsTo(entry, "AppleParavirtAccelerator"));
    result["conforms_io_accelerator"] = bool(IOObjectConformsTo(entry, "IOAccelerator"));
    result["conforms_io_service"] = bool(IOObjectConformsTo(entry, "IOService"));
    result["conforms_own_class"] = bool(name[0] && IOObjectConformsTo(entry, name));
    IOObjectRelease(entry);
    return result; // Unfiltered: retain physical, virtual, missing and failed lookups alike.
}
static QJsonObject deviceInfo(Report& report, id device, const QString& key) {
    QJsonObject result{{"present", bool(device)}};
    report.data[key] = result;
    report.save(key + ".object");
    if (!device) return result;
    result["classes"] = classes(device);
    result["selectors_before"] = selectors(device);
    report.data[key] = result;
    report.save(key + ".before_getters");
    std::uint64_t typed = 0, message = 0;
    @try {
        typed = [(id<MTLDevice>)device registryID];
        result["typed_registry_id"] = number(typed);
    } @catch (NSException* error) {
        result["typed_exception"] = QJsonObject{{"name", text(error.name)}, {"reason", text(error.reason)}};
    }
    report.data[key] = result;
    report.save(key + ".typed_getter");
    @try {
        message = reinterpret_cast<std::uint64_t (*)(id, SEL)>(objc_msgSend)(device, sel_registerName("registryID"));
        result["msgsend_registry_id"] = number(message);
    } @catch (NSException* error) {
        result["msgsend_exception"] = QJsonObject{{"name", text(error.name)}, {"reason", text(error.reason)}};
    }
    result["selectors_after"] = selectors(device);
    report.data[key] = result;
    report.save(key + ".after_getters");
    QJsonArray entries;
    entries.append(registry(typed));
    if (message != typed) entries.append(registry(message));
    result["registry_lookups"] = entries;
    return result;
}
int main(int argc, char** argv) {
    Report report{argc == 2 ? QString::fromLocal8Bit(argv[1]) : QStringLiteral("metal-probe.json")};
    try {
        report.save("before_gui_application");
        @try { @autoreleasepool {
            QGuiApplication app(argc, argv);
            report.data["qpa"] = QGuiApplication::platformName();
            report.data["qt_library_path"] = QLibraryInfo::path(QLibraryInfo::LibrariesPath);
            report.data["qt_plugin_path"] = QLibraryInfo::path(QLibraryInfo::PluginsPath);
            report.save("before_qrhi_create");
            QRhiMetalInitParams params;
            std::unique_ptr<QRhi> rhi(QRhi::create(QRhi::Metal, &params));
            report.data["qrhi_created"] = bool(rhi);
            report.save("after_qrhi_create");
            if (!rhi) return 2;
            const auto driver = rhi->driverInfo();
            report.data["qt_driver"] = QJsonObject{{"name", QString::fromUtf8(driver.deviceName)},
                {"type", int(driver.deviceType)}, {"device_id", number(driver.deviceId)},
                {"vendor_id", number(driver.vendorId)}, {"backend", int(rhi->backend())}};
            const auto* handles = static_cast<const QRhiMetalNativeHandles*>(rhi->nativeHandles());
            id selected = handles ? (id)handles->dev : nil;
            report.save("before_selected_device_inspection");
            report.data["selected"] = deviceInfo(report, selected, "selected");
            report.save("after_selected_device_inspection");
            id<MTLDevice> system = MTLCreateSystemDefaultDevice();
            report.data["same_system_default_object"] = bool(selected == system);
            report.data["system_default"] = deviceInfo(report, system, "system_default");
            [system release];
            const auto selectedId = report.data["selected"].toObject()["typed_registry_id"].toString();
            const auto defaultId = report.data["system_default"].toObject()["typed_registry_id"].toString();
            report.data["same_system_default_registry_id"] = !selectedId.isEmpty() && selectedId == defaultId;
            report.save("complete");
        } } @catch (NSException* error) {
            report.data["failed_after_stage"] = report.data["stage"];
            report.data["objc_exception"] = QJsonObject{{"name", text(error.name)}, {"reason", text(error.reason)}};
            report.save("objc_exception");
            return 4;
        }
        return 0;
    } catch (const std::exception& error) {
        report.data["failed_after_stage"] = report.data["stage"];
        report.data["cpp_exception"] = text(error.what());
        report.save("cpp_exception");
        return 3;
    }
}
