import Foundation
import Vapor

/**
 TODO:
 - No convective precip in NAM/HRRR
 - weather code
 - No 120/180m wind
 - Soil temp/moisture on different levels
 - DONE No cloudcover in NAM/HRRR on pressure levels -> RH to clouds implemented
 - DONE No diffuse/direct radiation in GFS -> separation model implemented
 */
public struct GfsController {
    func query(_ req: Request) -> EventLoopFuture<Response> {
        do {
            // API should only be used on the subdomain
            if req.headers[.host].contains(where: { $0.contains("open-meteo.com") && !$0.starts(with: "api.") }) {
                throw Abort.init(.notFound)
            }
            let generationTimeStart = Date()
            let params = try req.query.decode(GfsQuery.self)
            try params.validate()
            let elevationOrDem = try params.elevation ?? Dem90.read(lat: params.latitude, lon: params.longitude)
            let currentTime = Timestamp.now()
            
            let allowedRange = Timestamp(2022, 6, 8) ..< currentTime.add(86400 * 17)
            let timezone = try params.resolveTimezone()
            let time = try params.getTimerange(timezone: timezone, current: currentTime, forecastDays: params.forecast_days ?? 7, allowedRange: allowedRange)
            
            let hourlyTime = time.range.range(dtSeconds: 3600)
            let dailyTime = time.range.range(dtSeconds: 3600*24)
            
            let domains = [GfsDomain.gfs025, /*.nam_conus,*/ .hrrr_conus]
            
            guard let reader = try GfsMixer(domains: domains, lat: params.latitude, lon: params.longitude, elevation: elevationOrDem, mode: .terrainOptimised) else {
                throw ForecastapiError.noDataAvilableForThisLocation
            }
            
            
            // Start data prefetch to boooooooost API speed :D
            if let hourlyVariables = params.hourly {
                try reader.prefetchData(variables: hourlyVariables, time: hourlyTime)
            }
            if let dailyVariables = params.daily {
                try reader.prefetchData(variables: dailyVariables, time: dailyTime)
            }
            
            let hourly: ApiSection? = try params.hourly.map { variables in
                var res = [ApiColumn]()
                res.reserveCapacity(variables.count)
                for variable in variables {
                    let d = try reader.get(variable: variable, time: hourlyTime).conertAndRound(params: params).toApi(name: variable.name)
                    assert(hourlyTime.count == d.data.count)
                    res.append(d)
                }
                return ApiSection(name: "hourly", time: hourlyTime, columns: res)
            }
            
            let currentWeather: ForecastapiResult.CurrentWeather?
            if params.current_weather == true {
                let starttime = currentTime.floor(toNearest: 3600)
                let time = TimerangeDt(start: starttime, nTime: 1, dtSeconds: 3600)
                guard let reader = try GfsMixer(domains: domains, lat: params.latitude, lon: params.longitude, elevation: elevationOrDem, mode: .terrainOptimised) else {
                    throw ForecastapiError.noDataAvilableForThisLocation
                }
                let temperature = try reader.get(variable: .temperature_2m, time: time).conertAndRound(params: params)
                let winddirection = try reader.get(variable: .winddirection_10m, time: time).conertAndRound(params: params)
                let windspeed = try reader.get(variable: .windspeed_10m, time: time).conertAndRound(params: params)
                //let weathercode = try reader.get(variable: .weathercode).conertAndRound(params: params)
                currentWeather = ForecastapiResult.CurrentWeather(
                    temperature: temperature.data[0],
                    windspeed: windspeed.data[0],
                    winddirection: winddirection.data[0],
                    weathercode: .nan, //weathercode.data[0],
                    temperature_unit: temperature.unit,
                    windspeed_unit: windspeed.unit,
                    winddirection_unit: winddirection.unit,
                    weathercode_unit: .dimensionless, //weathercode.unit,
                    time: starttime
                )
            } else {
                currentWeather = nil
            }
            
            let daily: ApiSection? = try params.daily.map { dailyVariables in
                var res = [ApiColumn]()
                res.reserveCapacity(dailyVariables.count)
                var riseSet: (rise: [Timestamp], set: [Timestamp])? = nil
                
                for variable in dailyVariables {
                    if variable == .sunrise || variable == .sunset {
                        // only calculate sunrise/set once
                        let times = riseSet ?? Zensun.calculateSunRiseSet(timeRange: time.range, lat: params.latitude, lon: params.longitude, utcOffsetSeconds: time.utcOffsetSeconds)
                        riseSet = times
                        if variable == .sunset {
                            res.append(ApiColumn(variable: variable.rawValue, unit: params.timeformatOrDefault.unit, data: .timestamp(times.set)))
                        } else {
                            res.append(ApiColumn(variable: variable.rawValue, unit: params.timeformatOrDefault.unit, data: .timestamp(times.rise)))
                        }
                        continue
                    }
                    let d = try reader.getDaily(variable: variable, params: params, time: dailyTime).toApi(name: variable.rawValue)
                    assert(dailyTime.count == d.data.count)
                    res.append(d)
                }
                return ApiSection(name: "daily", time: dailyTime, columns: res)
            }
            
            let generationTimeMs = Date().timeIntervalSince(generationTimeStart) * 1000
            let out = ForecastapiResult(
                latitude: reader.mixer.modelLat,
                longitude: reader.mixer.modelLon,
                elevation: reader.mixer.targetElevation,
                generationtime_ms: generationTimeMs,
                utc_offset_seconds: time.utcOffsetSeconds,
                timezone: timezone,
                current_weather: currentWeather,
                sections: [hourly, daily].compactMap({$0}),
                timeformat: params.timeformatOrDefault
            )
            return req.eventLoop.makeSucceededFuture(try out.response(format: params.format ?? .json))
        } catch {
            return req.eventLoop.makeFailedFuture(error)
        }
    }
}


struct GfsQuery: Content, QueryWithStartEndDateTimeZone {
    let latitude: Float
    let longitude: Float
    let hourly: [GfsVariableCombined]?
    let daily: [GfsDailyWeatherVariable]?
    let current_weather: Bool?
    let elevation: Float?
    let timezone: String?
    let temperature_unit: TemperatureUnit?
    let windspeed_unit: WindspeedUnit?
    let precipitation_unit: PrecipitationUnit?
    let timeformat: Timeformat?
    let past_days: Int?
    let forecast_days: Int?
    let format: ForecastResultFormat?
    
    /// iso starting date `2022-02-01`
    let start_date: IsoDate?
    /// included end date `2022-06-01`
    let end_date: IsoDate?
    
    func validate() throws {
        if latitude > 90 || latitude < -90 || latitude.isNaN {
            throw ForecastapiError.latitudeMustBeInRangeOfMinus90to90(given: latitude)
        }
        if longitude > 180 || longitude < -180 || longitude.isNaN {
            throw ForecastapiError.longitudeMustBeInRangeOfMinus180to180(given: longitude)
        }
        if let forecast_days = forecast_days, forecast_days <= 0 || forecast_days > 16 {
            throw ForecastapiError.forecastDaysInvalid(given: forecast_days, allowed: 0...16)
        }
        if daily?.count ?? 0 > 0 && timezone == nil {
            throw ForecastapiError.timezoneRequired
        }
    }
    
    var timeformatOrDefault: Timeformat {
        return timeformat ?? .iso8601
    }
}


enum GfsDailyWeatherVariable: String, Codable {
    case temperature_2m_max
    case temperature_2m_min
    case apparent_temperature_max
    case apparent_temperature_min
    case precipitation_sum
    case snowfall_sum
    //case rain_sum
    //case showers_sum
    //case weathercode
    case shortwave_radiation_sum
    // cloudcover_total_max?
    case windspeed_10m_max
    case windgusts_10m_max
    case winddirection_10m_dominant
    /// TODO implement aggregation
    //case sunshine_hours
    case precipitation_hours
    case sunrise
    case sunset
    case et0_fao_evapotranspiration
}

enum GfsVariableDerivedSurface: String, Codable, CaseIterable {
    case apparent_temperature
    case relativehumitidy_2m
    case dewpoint_2m
    case windspeed_10m
    case winddirection_10m
    case windspeed_80m
    case winddirection_80m
    /*case windspeed_120m
    case winddirection_120m
    case windspeed_180m
    case winddirection_180m*/
    case direct_normal_irradiance
    case direct_normal_irradiance_instant
    case direct_radiation
    case direct_radiation_instant
    case diffuse_radiation_instant
    case shortwave_radiation_instant
    case evapotranspiration
    case et0_fao_evapotranspiration
    case vapor_pressure_deficit
    case snowfall
    case surface_pressure
    case terrestrial_radiation
    case terrestrial_radiation_instant
}

/**
 Types of pressure level variables
 */
enum GfsPressureVariableDerivedType: String, CaseIterable {
    case windspeed
    case winddirection
    case dewpoint
}

/**
 A pressure level variable on a given level in hPa / mb
 */
struct GfsPressureVariableDerived: PressureVariableRespresentable {
    let variable: GfsPressureVariableDerivedType
    let level: Int
}

typealias GfsVariableDerived = SurfaceAndPressureVariable<GfsVariableDerivedSurface, GfsPressureVariableDerived>

typealias GfsVariableCombined = VariableOrDerived<GfsVariable, GfsVariableDerived>

typealias GfsReader = GenericReader<GfsDomain, GfsVariable>

typealias GfsMixer = GenericReaderMixerCached<GfsDomain, GfsVariable>

extension GfsMixer {
    func getDaily(variable: GfsDailyWeatherVariable, params: GfsQuery, time timeDaily: TimerangeDt) throws -> DataAndUnit {
        let time = timeDaily.with(dtSeconds: mixer.reader.last!.domain.dtSeconds)
        switch variable {
        case .temperature_2m_max:
            let data = try get(variable: .temperature_2m, time: time).conertAndRound(params: params)
            return DataAndUnit(data.data.max(by: 24), data.unit)
        case .temperature_2m_min:
            let data = try get(variable: .temperature_2m, time: time).conertAndRound(params: params)
            return DataAndUnit(data.data.min(by: 24), data.unit)
        case .apparent_temperature_max:
            let data = try get(variable: .apparent_temperature, time: time).conertAndRound(params: params)
            return DataAndUnit(data.data.max(by: 24), data.unit)
        case .apparent_temperature_min:
            let data = try get(variable: .apparent_temperature, time: time).conertAndRound(params: params)
            return DataAndUnit(data.data.min(by: 24), data.unit)
        case .precipitation_sum:
            // rounding is required, becuse floating point addition results in uneven numbers
            let data = try get(variable: .precipitation, time: time).conertAndRound(params: params)
            return DataAndUnit(data.data.sum(by: 24).round(digits: 2), data.unit)
        /*case .weathercode:
            // not 100% corrct
            let data = try get(variable: .weathercode).conertAndRound(params: params)
            return DataAndUnit(data.data.max(by: 24), data.unit)*/
        case .shortwave_radiation_sum:
            let data = try get(variable: .shortwave_radiation, time: time).conertAndRound(params: params)
            // 3600s only for hourly data of source
            return DataAndUnit(data.data.map({$0*0.0036}).sum(by: 24).round(digits: 2), .megaJoulesPerSquareMeter)
        case .windspeed_10m_max:
            let data = try get(variable: .windspeed_10m, time: time).conertAndRound(params: params)
            return DataAndUnit(data.data.max(by: 24), data.unit)
        case .windgusts_10m_max:
            let data = try get(variable: .windgusts_10m, time: time).conertAndRound(params: params)
            return DataAndUnit(data.data.max(by: 24), data.unit)
        case .winddirection_10m_dominant:
            // vector addition
            let u = try get(variable: .wind_u_component_10m, time: time).data.sum(by: 24)
            let v = try get(variable: .wind_v_component_10m, time: time).data.sum(by: 24)
            let direction = Meteorology.windirectionFast(u: u, v: v)
            return DataAndUnit(direction, .degreeDirection)
        //case .sunshine_hours:
            /// TODO need sunrise and set time for correct numbers
            //fatalError()
        case .precipitation_hours:
            let data = try get(variable: .precipitation, time: time).conertAndRound(params: params)
            return DataAndUnit(data.data.map({$0 > 0.001 ? 1 : 0}).sum(by: 24), .hours)
        case .sunrise:
            return DataAndUnit([],.hours)
        case .sunset:
            return DataAndUnit([],.hours)
        case .et0_fao_evapotranspiration:
            let data = try get(variable: .et0_fao_evapotranspiration, time: time).conertAndRound(params: params)
            return DataAndUnit(data.data.sum(by: 24).round(digits: 2), data.unit)
        case .snowfall_sum:
            let data = try get(variable: .snowfall, time: time).conertAndRound(params: params)
            return DataAndUnit(data.data.sum(by: 24).round(digits: 2), data.unit)
        /*case .rain_sum:
            let data = try get(variable: .rain).conertAndRound(params: params)
            return DataAndUnit(data.data.sum(by: 24).round(digits: 2), data.unit)
        case .showers_sum:
            let data = try get(variable: .showers).conertAndRound(params: params)
            return DataAndUnit(data.data.sum(by: 24).round(digits: 2), data.unit)*/
        }
    }
    
    func get(variable: GfsVariableCombined, time: TimerangeDt) throws -> DataAndUnit {
        switch variable {
        case .raw(let variable):
            return try get(variable: variable, time: time)
        case .derived(let variable):
            return try get(variable: variable, time: time)
        }
    }
    
    func prefetchData(variable: Variable, time: TimerangeDt) throws {
        try mixer.prefetchData(variable: variable, time: time)
    }
    
    func prefetchData(variables: [GfsDailyWeatherVariable], time timeDaily: TimerangeDt) throws {
        let time = timeDaily.with(dtSeconds: mixer.reader.last!.domain.dtSeconds)
        for variable in variables {
            switch variable {
            case .temperature_2m_max:
                fallthrough
            case .temperature_2m_min:
                try prefetchData(variable: .temperature_2m, time: time)
            case .apparent_temperature_max:
                fallthrough
            case .apparent_temperature_min:
                try prefetchData(variable: .temperature_2m, time: time)
                try prefetchData(variable: .wind_u_component_10m, time: time)
                try prefetchData(variable: .wind_v_component_10m, time: time)
                try prefetchData(variable: .relativehumidity_2m, time: time)
                try prefetchData(variable: .shortwave_radiation, time: time)
            case .precipitation_sum:
                try prefetchData(variable: .precipitation, time: time)
            //case .weathercode:
            //    try prefetchData(variable: .weathercode)
            case .shortwave_radiation_sum:
                try prefetchData(variable: .shortwave_radiation, time: time)
            case .windspeed_10m_max:
                try prefetchData(variable: .wind_u_component_10m, time: time)
                try prefetchData(variable: .wind_v_component_10m, time: time)
            case .windgusts_10m_max:
                try prefetchData(variable: .windgusts_10m, time: time)
            case .winddirection_10m_dominant:
                try prefetchData(variable: .wind_u_component_10m, time: time)
                try prefetchData(variable: .wind_v_component_10m, time: time)
            case .precipitation_hours:
                try prefetchData(variable: .precipitation, time: time)
            case .sunrise:
                break
            case .sunset:
                break
            case .et0_fao_evapotranspiration:
                try prefetchData(variable: .shortwave_radiation, time: time)
                try prefetchData(variable: .temperature_2m, time: time)
                try prefetchData(variable: .relativehumidity_2m, time: time)
                try prefetchData(variable: .wind_u_component_10m, time: time)
                try prefetchData(variable: .wind_v_component_10m, time: time)
            case .snowfall_sum:
                try prefetchData(variable: .precipitation, time: time)
                try prefetchData(variable: .frozen_precipitation_percent, time: time)
            /*case .rain_sum:
                try prefetchData(variable: .rain)
            case .showers_sum:
                try prefetchData(variable: .showers)*/
            }
        }
    }
    
    func prefetchData(variable: GfsSurfaceVariable, time: TimerangeDt) throws {
        try prefetchData(variable: .surface(variable), time: time)
    }
    
    func prefetchData(variables: [GfsVariableCombined], time: TimerangeDt) throws {
        for variable in variables {
            switch variable {
            case .raw(let variable):
                try prefetchData(variable: variable, time: time)
            case .derived(let variable):
                switch variable {
                case .surface(let surface):
                    switch surface {
                    case .apparent_temperature:
                        try prefetchData(variable: .temperature_2m, time: time)
                        try prefetchData(variable: .wind_u_component_10m, time: time)
                        try prefetchData(variable: .wind_v_component_10m, time: time)
                        try prefetchData(variable: .relativehumidity_2m, time: time)
                        try prefetchData(variable: .shortwave_radiation, time: time)
                    case .relativehumitidy_2m:
                        try prefetchData(variable: .relativehumidity_2m, time: time)
                    case .windspeed_10m:
                        try prefetchData(variable: .wind_u_component_10m, time: time)
                        try prefetchData(variable: .wind_v_component_10m, time: time)
                    case .winddirection_10m:
                        try prefetchData(variable: .wind_u_component_10m, time: time)
                        try prefetchData(variable: .wind_v_component_10m, time: time)
                    case .windspeed_80m:
                        try prefetchData(variable: .wind_u_component_80m, time: time)
                        try prefetchData(variable: .wind_v_component_80m, time: time)
                    case .winddirection_80m:
                        try prefetchData(variable: .wind_u_component_80m, time: time)
                        try prefetchData(variable: .wind_v_component_80m, time: time)
                    /*case .windspeed_120m:
                        try prefetchData(variable: .u_120m)
                        try prefetchData(variable: .v_120m)
                    case .winddirection_120m:
                        try prefetchData(variable: .u_120m)
                        try prefetchData(variable: .v_120m)
                    case .windspeed_180m:
                        try prefetchData(variable: .u_180m)
                        try prefetchData(variable: .v_180m)
                    case .winddirection_180m:
                        try prefetchData(variable: .u_180m)
                        try prefetchData(variable: .v_180m)*/
                    /*case .direct_normal_irradiance:
                        try prefetchData(variable: .direct_radiation)*/
                    case .evapotranspiration:
                        try prefetchData(variable: .latent_heatflux, time: time)
                    case .vapor_pressure_deficit:
                        try prefetchData(variable: .temperature_2m, time: time)
                        try prefetchData(variable: .relativehumidity_2m, time: time)
                    case .et0_fao_evapotranspiration:
                        try prefetchData(variable: .shortwave_radiation, time: time)
                        try prefetchData(variable: .temperature_2m, time: time)
                        try prefetchData(variable: .relativehumidity_2m, time: time)
                        try prefetchData(variable: .wind_u_component_10m, time: time)
                        try prefetchData(variable: .wind_v_component_10m, time: time)
                    case .snowfall:
                        try prefetchData(variable: .frozen_precipitation_percent, time: time)
                        try prefetchData(variable: .precipitation, time: time)
                    case .surface_pressure:
                        try prefetchData(variable: .pressure_msl, time: time)
                        try prefetchData(variable: .temperature_2m, time: time)
                    case .terrestrial_radiation:
                        break
                    case .terrestrial_radiation_instant:
                        break
                    case .dewpoint_2m:
                        try prefetchData(variable: .temperature_2m, time: time)
                        try prefetchData(variable: .relativehumidity_2m, time: time)
                    case .diffuse_radiation_instant:
                        try prefetchData(variable: .diffuse_radiation, time: time)
                    case .direct_normal_irradiance:
                        fallthrough
                    case .direct_normal_irradiance_instant:
                        fallthrough
                    case .direct_radiation:
                        fallthrough
                    case .direct_radiation_instant:
                        try prefetchData(variable: .shortwave_radiation, time: time)
                        try prefetchData(variable: .diffuse_radiation, time: time)
                    case .shortwave_radiation_instant:
                        try prefetchData(variable: .shortwave_radiation, time: time)
                    }
                case .pressure(let v):
                    switch v.variable {
                    case .windspeed:
                        fallthrough
                    case .winddirection:
                        try mixer.prefetchData(variable: .pressure(GfsPressureVariable(variable: .wind_u_component, level: v.level)), time: time)
                        try mixer.prefetchData(variable: .pressure(GfsPressureVariable(variable: .wind_v_component, level: v.level)), time: time)
                    case .dewpoint:
                        try mixer.prefetchData(variable: .pressure(GfsPressureVariable(variable: .temperature, level: v.level)), time: time)
                        try mixer.prefetchData(variable: .pressure(GfsPressureVariable(variable: .relativehumidity, level: v.level)), time: time)
                    }
                }
            }
        }
    }
    
    func get(variable: GfsSurfaceVariable, time: TimerangeDt) throws -> DataAndUnit {
        return try get(variable: .surface(variable), time: time)
    }
    
    func get(variable: GfsVariableDerivedSurface, time: TimerangeDt) throws -> DataAndUnit {
        return try get(variable: .derived(.surface(variable)), time: time)
    }
    
    
    
    func get(variable: GfsVariableDerived, time: TimerangeDt) throws -> DataAndUnit {
        switch variable {
        case .surface(let gfsVariableDerivedSurface):
            switch gfsVariableDerivedSurface {
            case .windspeed_10m:
                let u = try get(variable: .wind_u_component_10m, time: time).data
                let v = try get(variable: .wind_v_component_10m, time: time).data
                let speed = zip(u,v).map(Meteorology.windspeed)
                return DataAndUnit(speed, .ms)
            case .winddirection_10m:
                let u = try get(variable: .wind_u_component_10m, time: time).data
                let v = try get(variable: .wind_v_component_10m, time: time).data
                let direction = Meteorology.windirectionFast(u: u, v: v)
                return DataAndUnit(direction, .degreeDirection)
            case .windspeed_80m:
                let u = try get(variable: .wind_u_component_80m, time: time).data
                let v = try get(variable: .wind_v_component_80m, time: time).data
                let speed = zip(u,v).map(Meteorology.windspeed)
                return DataAndUnit(speed, .ms)
            case .winddirection_80m:
                let u = try get(variable: .wind_u_component_80m, time: time).data
                let v = try get(variable: .wind_v_component_80m, time: time).data
                let direction = Meteorology.windirectionFast(u: u, v: v)
                return DataAndUnit(direction, .degreeDirection)
            case .apparent_temperature:
                let windspeed = try get(variable: .windspeed_10m, time: time).data
                let temperature = try get(variable: .temperature_2m, time: time).data
                let relhum = try get(variable: .relativehumidity_2m, time: time).data
                let radiation = try get(variable: .shortwave_radiation, time: time).data
                return DataAndUnit(Meteorology.apparentTemperature(temperature_2m: temperature, relativehumidity_2m: relhum, windspeed_10m: windspeed, shortware_radiation: radiation), .celsius)
            case .evapotranspiration:
                let latent = try get(variable: .latent_heatflux, time: time).data
                let evapotranspiration = latent.map(Meteorology.evapotranspiration)
                return DataAndUnit(evapotranspiration, .millimeter)
            case .vapor_pressure_deficit:
                let temperature = try get(variable: .temperature_2m, time: time).data
                let rh = try get(variable: .relativehumidity_2m, time: time).data
                let dewpoint = zip(temperature,rh).map(Meteorology.dewpoint)
                return DataAndUnit(zip(temperature,dewpoint).map(Meteorology.vaporPressureDeficit), .kiloPascal)
            case .et0_fao_evapotranspiration:
                let exrad = Zensun.extraTerrestrialRadiationBackwards(latitude: mixer.modelLat, longitude: mixer.modelLon, timerange: time)
                let swrad = try get(variable: .shortwave_radiation, time: time).data
                let temperature = try get(variable: .temperature_2m, time: time).data
                let windspeed = try get(variable: .windspeed_10m, time: time).data
                let rh = try get(variable: .relativehumidity_2m, time: time).data
                let dewpoint = zip(temperature,rh).map(Meteorology.dewpoint)
                
                let et0 = swrad.indices.map { i in
                    return Meteorology.et0Evapotranspiration(temperature2mCelsius: temperature[i], windspeed10mMeterPerSecond: windspeed[i], dewpointCelsius: dewpoint[i], shortwaveRadiationWatts: swrad[i], elevation: mixer.targetElevation, extraTerrestrialRadiation: exrad[i], dtSeconds: 3600)
                }
                return DataAndUnit(et0, .millimeter)
            case .snowfall:
                let frozen_precipitation_percent = try get(variable: .frozen_precipitation_percent, time: time).data
                let precipitation = try get(variable: .precipitation, time: time).data
                let snowfall = zip(frozen_precipitation_percent, precipitation).map({
                    max($0/100 * $1 * 0.7, 0)
                })
                return DataAndUnit(snowfall, SiUnit.centimeter)
            case .relativehumitidy_2m:
                return try get(variable: .relativehumidity_2m, time: time)
            case .surface_pressure:
                let temperature = try get(variable: .temperature_2m, time: time).data
                let pressure = try get(variable: .pressure_msl, time: time)
                return DataAndUnit(Meteorology.surfacePressure(temperature: temperature, pressure: pressure.data, elevation: mixer.targetElevation), pressure.unit)
            case .terrestrial_radiation:
                /// Use center averaged
                let solar = Zensun.extraTerrestrialRadiationBackwards(latitude: mixer.modelLat, longitude: mixer.modelLon, timerange: time)
                return DataAndUnit(solar, .wattPerSquareMeter)
            case .terrestrial_radiation_instant:
                /// Use center averaged
                let solar = Zensun.extraTerrestrialRadiationInstant(latitude: mixer.modelLat, longitude: mixer.modelLon, timerange: time)
                return DataAndUnit(solar, .wattPerSquareMeter)
            case .dewpoint_2m:
                let temperature = try get(variable: .temperature_2m, time: time)
                let rh = try get(variable: .relativehumidity_2m, time: time)
                return DataAndUnit(zip(temperature.data, rh.data).map(Meteorology.dewpoint), temperature.unit)
            case .shortwave_radiation_instant:
                let sw = try get(variable: .shortwave_radiation, time: time)
                let factor = Zensun.backwardsAveragedToInstantFactor(time: time, latitude: mixer.modelLat, longitude: mixer.modelLon)
                return DataAndUnit(zip(sw.data, factor).map(*), sw.unit)
            case .direct_normal_irradiance:
                let dhi = try get(variable: .direct_radiation, time: time).data
                let dni = Zensun.calculateBackwardsDNI(directRadiation: dhi, latitude: mixer.modelLat, longitude: mixer.modelLon, timerange: time)
                return DataAndUnit(dni, .wattPerSquareMeter)
            case .direct_normal_irradiance_instant:
                let direct = try get(variable: .direct_radiation_instant, time: time)
                let dni = Zensun.calculateInstantDNI(directRadiation: direct.data, latitude: mixer.modelLat, longitude: mixer.modelLon, timerange: time)
                return DataAndUnit(dni, direct.unit)
            case .direct_radiation:
                let diffuse = try get(variable: .diffuse_radiation, time: time)
                let swrad = try get(variable: .shortwave_radiation, time: time)
                return DataAndUnit(zip(swrad.data, diffuse.data).map(-), diffuse.unit)
            case .direct_radiation_instant:
                let direct = try get(variable: .direct_radiation, time: time)
                let factor = Zensun.backwardsAveragedToInstantFactor(time: time, latitude: mixer.modelLat, longitude: mixer.modelLon)
                return DataAndUnit(zip(direct.data, factor).map(*), direct.unit)
            case .diffuse_radiation_instant:
                let diff = try get(variable: .diffuse_radiation, time: time)
                let factor = Zensun.backwardsAveragedToInstantFactor(time: time, latitude: mixer.modelLat, longitude: mixer.modelLon)
                return DataAndUnit(zip(diff.data, factor).map(*), diff.unit)
            }
        case .pressure(let v):
            switch v.variable {
            case .windspeed:
                let u = try get(variable: .pressure(GfsPressureVariable(variable: .wind_u_component, level: v.level)), time: time)
                let v = try get(variable: .pressure(GfsPressureVariable(variable: .wind_v_component, level: v.level)), time: time)
                let speed = zip(u.data,v.data).map(Meteorology.windspeed)
                return DataAndUnit(speed, u.unit)
            case .winddirection:
                let u = try get(variable: .pressure(GfsPressureVariable(variable: .wind_u_component, level: v.level)), time: time).data
                let v = try get(variable: .pressure(GfsPressureVariable(variable: .wind_v_component, level: v.level)), time: time).data
                let direction = Meteorology.windirectionFast(u: u, v: v)
                return DataAndUnit(direction, .degreeDirection)
            case .dewpoint:
                let temperature = try get(variable: .pressure(GfsPressureVariable(variable: .temperature, level: v.level)), time: time)
                let rh = try get(variable: .pressure(GfsPressureVariable(variable: .relativehumidity, level: v.level)), time: time)
                return DataAndUnit(zip(temperature.data, rh.data).map(Meteorology.dewpoint), temperature.unit)
            }
        }
    }
}
