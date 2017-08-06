#include<stdio.h>
#include<stdlib.h>
#include<string.h>
#include<math.h>
#include<time.h>

#define MAX_NODE 100000 // Max length of galaxy merger tree

#define NMETALS 5 // Number of input metallicity
#define NUM_Z 40 // Number of interpolated metallicity
#define MAX_Z 39 // Maximum metallicity index
#define MIN_Z 0 // Minimum metallicity index

#define SURFACE_AREA 1.1965e40 // 4*pi*(10 pc)**2 unit cm^2
#define JANSKY(x) (3.34e4*(x)*(x)/SURFACE_AREA) // Convert erg/s/A to Jy at 10 pc
#define M_AB(x) (-2.5*log10(x) + 8.9) // Convert Jansky to AB magnitude
#define TOL 1e-50 // Minimum Flux

time_t sTime;
// Meraxes output
int **firstProgenitor = NULL;
int **nextProgenitor = NULL;
float **galMetals = NULL;
float **galSFR = NULL;
// Variable for galaxy merger tree
struct node {
    short snap;
    short metals;
    float sfr;
};
//
char sedAge[] = "/lustre/projects/p113_astro/yqiu/magcalc/input/sed_age.bin";
char sedWaves[] = "/lustre/projects/p113_astro/yqiu/magcalc/input/sed_waves.bin";
char *sedTemplates[NMETALS] = {"/lustre/projects/p113_astro/yqiu/magcalc/input/sed_0.001.bin",
                               "/lustre/projects/p113_astro/yqiu/magcalc/input/sed_0.004.bin",
                               "/lustre/projects/p113_astro/yqiu/magcalc/input/sed_0.008.bin",
                               "/lustre/projects/p113_astro/yqiu/magcalc/input/sed_0.020.bin",
                               "/lustre/projects/p113_astro/yqiu/magcalc/input/sed_0.040.bin"};
// Struct for SED templates
struct template {
    int nAge;
    double *age;
    int nWaves;
    double *waves;
    int nZ;
    // The first dimension refers to metallicities and ages
    // The list dimension refers to wavelengths
    double **data;
};


FILE *open_file(char *fName, char *mode) {
/* Open the file with specific mode */
    FILE *fp;
    if ((fp = fopen(fName, mode)) == NULL) {
        printf("File open error: \"%s\"!\n", fName);
        exit(0);
    }
    printf("# File opened: \"%s\"!\n", fName);
    return fp;
}


inline void report(int i, int tot) {
    int n = tot > 10 ? tot/10:1;
    if (i%n == 0) {
        printf("# %5.1f%% complete!\r", 100.*(i + 1)/tot);      
        fflush(stdout);
    }
}


double **malloc_2d_double(int nRow, int nCol) {
    int i;
    double **target;
    target = (double**)malloc(nRow*sizeof(double*));
    for(i = 0; i < nRow; ++i) 
        target[i] = (double*)malloc(nCol*sizeof(double));
    return target;
}


void free_2d_double(double **p, int nRow) {
    int i;
    for(i = 0; i < nRow; ++i)
        free(p[i]);
    free(p);
}


void free_template(struct template *spectra) {
    free(spectra->age);
    free(spectra->waves);
    free_2d_double(spectra->data, spectra->nZ*spectra->nWaves);
}


void timing_start(char* text) {
    sTime = time(NULL);
    printf("#**********************************************************\n");
    printf(text);
}

void timing_end(void) {
    int elapsedTime;
    elapsedTime = (int)difftime(time(NULL), sTime);
    printf("# Done!\n");
    printf("# Elapsed time: %d min %d sec\n", elapsedTime/60, elapsedTime%60);
    printf("#**********************************************************\n\n");
}


inline double interp(double xp, double *x, double *y, int nPts) {
    /* Interpolate a given points */
    int idx0, idx1, idxMid;
    if((xp < x[0]) || (xp > x[nPts - 1])) {
        printf("Error: Point %10.5e is beyond the interpolation region\n", xp);
        exit(0);
    }
    idx0 = 0;
    idx1 = nPts - 1;
    while(idx1 - idx0 > 1) {
        idxMid = (idx0 + idx1)/2;
        if(xp > x[idxMid])
            idx0 = idxMid;
        else if(xp < x[idxMid])
            idx1 = idxMid;
        else
            return y[idxMid];
    }
    return y[idx0] + (y[idx1] - y[idx0])*(xp - x[idx0])/(x[idx1] - x[idx0]);
}


inline double trapz_table(double *y, double *x, int nPts, double a, double b) {
    /* Integrate tabular data from a to b */
    int i;
    int idx0 = 0;
    int idx1 = nPts - 1;
    int idxMid;
    double ya, yb;
    double I;
    if (x[0] > a) {
        printf("Error: Integration range %10.5e is beyond the tabular data\n", a);
        exit(0);
    }
    if (x[nPts - 1] < b) {
        printf("Error: Integration range %10.5e is beyond the tabular data\n", b); 
        exit(0);
    }
    if (a > b) {
        printf("Error: a must be smaller than b\n");
        exit(0);
    }
    // Use bisection to search the interval that contains a
    while(idx1 - idx0 > 1) {
        idxMid = (idx0 + idx1)/2;
        if (a > x[idxMid])
            idx0 = idxMid;
        else if (a < x[idxMid])
            idx1 = idxMid;
        else
            break;
    }

    ya = y[idx0] + (y[idx1] - y[idx0])*(a - x[idx0])/(x[idx1] - x[idx0]);
    if(b <= x[idx1]) {
        yb = y[idx0] + (y[idx1] - y[idx0])*(b - x[idx0])/(x[idx1] - x[idx0]);
        return (b - a)*(yb + ya)/2.;
    }
    else 
        I = (x[idx1] - a)*(y[idx1] + ya)/2.;

    for(i = idx1; i < nPts - 1; ++i) {
        if (x[i + 1] < b)
            I += (x[i + 1] - x[i])*(y[i + 1] + y[i])/2.;
        else if (x[i] < b) {
            yb = y[i] + (y[i + 1] - y[i])*(b - x[i])/(x[i + 1] - x[i]);
            I += (b - x[i])*(yb + y[i])/2.;
        }
        else
            break;
    }
    return I;
}


inline double trapz_filter(double *filter, double *flux, double *waves, int nWaves) {
    /* integrate the flux in a filter */
    int i;
    double y0 = filter[0]*flux[0];
    double y1;
    double I = 0.;
    for(i = 1; i < nWaves; ++i) {
        y1 = filter[i]*flux[i];
        I += (waves[i] - waves[i - 1])*(y0 + y1)/2.;
        y0 = y1;
    }
    return I;
}


void read_sed_templates(struct template *spectra) {
    /* SED templates must be normalised to 1 M_sun with unit erg/s/A 
     * Wavelengths must be in a unit of angstrom
     * Ages must be in a unit of year 
     * The first dimension of templates must be wavelengths
     * The last dimension of templates must be ages
     */
    FILE *fp;
    int i, j;

    timing_start("# Read SED templates\n");
    fp = open_file(sedAge, "r");
    fread(&spectra->nAge, sizeof(int), 1, fp);
    spectra->age = (double*)malloc(spectra->nAge*sizeof(double));
    fread(spectra->age, sizeof(double), spectra->nAge, fp);
    fclose(fp);

    fp = open_file(sedWaves, "r");
    fread(&spectra->nWaves, sizeof(int), 1, fp);
    spectra->waves = (double*)malloc(spectra->nWaves*sizeof(double));
    fread(spectra->waves, sizeof(double), spectra->nWaves, fp);
    fclose(fp);

    spectra->nZ = NMETALS;
    spectra->data = malloc_2d_double(spectra->nZ*spectra->nWaves, spectra->nAge);
    for(i = 0; i < NMETALS; ++i) {
        fp = open_file(sedTemplates[i], "r");
        for(j = 0; j < spectra->nWaves; ++j) 
            fread(spectra->data[i*spectra->nWaves + j], sizeof(double), spectra->nAge, fp);
        fclose(fp);
    }

    timing_end();
}


double *init_templates_sp(double *ageList, int nAgeList) {
    int i, j, k;
    double refMetals[NMETALS] = {0., 3., 7., 19., 39.};
    struct template rawSpectra;
    int nWaves = 1221;
    double *waves;
    // Spectra to be interploated along metallicities
    // The first dimension refers to ages and wavelengths
    // The last dimension refers to metallicites
    double **refSpectra;
    // Output
    // The first dimension refers to metallicites
    // The second dimension refers to ages
    // The last dimension refers to wavelengths
    double *fluxTmp;
    double *pData;

    read_sed_templates(&rawSpectra);
    timing_start("# Process SED templates\n");
    nWaves = rawSpectra.nWaves;
    waves = (double*)malloc(nWaves*sizeof(double));
    memcpy(waves, rawSpectra.waves, nWaves*sizeof(double));
    // Integrate raw SED templates over time
    printf("# Integrate SED templates over time\n");
    refSpectra = malloc_2d_double(nAgeList*nWaves, NMETALS);
    
    for(i = 0; i < nAgeList; report(i++, nAgeList)) 
        for(j = 0; j < nWaves; ++j)  {
            pData = refSpectra[i*nWaves + j];
            for(k = 0; k < NMETALS; ++k) {
                if (i == 0) {
                    // The first time step of SED templates is typicall not zero
                    // Here assumes that the templates is constant beween zero
                    // and the first time step
                    pData[k] = rawSpectra.data[k*nWaves + j][0]*rawSpectra.age[0];
                    pData[k] += trapz_table(rawSpectra.data[k*nWaves + j],
                                            rawSpectra.age, rawSpectra.nAge, 
                                            rawSpectra.age[0], ageList[i]);
                }
                else
                    pData[k] = trapz_table(rawSpectra.data[k*nWaves + j], 
                                           rawSpectra.age, rawSpectra.nAge, 
                                           ageList[i - 1], ageList[i]);
                // Convert to rest frame flux                       
                pData[k] *= JANSKY(waves[j]);
            }
        }
    free_template(&rawSpectra);
    // Interpolate SED templates along metallicites
    printf("# Interpolate SED templates along metallicities\n");
    fluxTmp = (double*)malloc(NUM_Z*nAgeList*nWaves*sizeof(double));
    pData = fluxTmp;
    for(i = 0; i < NUM_Z; ++i)
        for(j = 0; j < nAgeList; ++j) 
            for(k = 0; k < nWaves; ++k) 
                *pData++ = interp((double)i, refMetals, refSpectra[j*nWaves + k], NMETALS);
        
    free(refSpectra);
    timing_end();
    return fluxTmp;
}


double *init_templates_ph(double z, double *ageList, int nAgeList, 
                          double *filters, int nRest, int nObs, double *absorption) {
    int i, j, k;
    double refMetals[NMETALS] = {0., 3., 7., 19., 39.};
    int nFilter = nRest + nObs;
    double *pFilter;   
    struct template rawSpectra;
    int nWaves;
    double *waves;
    // Spectra after integration over time
    // The first dimension refers to metallicites and ages
    // The last dimension refers to wavelengths
    double **spectra;
    // Spectra to be interploated along metallicities
    // The first dimension refers to filters and ages
    // Thw last dimension refers to metallicites
    double **refSpectra;
    // Output
    // The first dimension refers to metallicites
    // The second dimension refers to ages
    // The last dimension refers to wavelengths
    double *fluxTmp;
    double *pData;

    read_sed_templates(&rawSpectra);
    timing_start("# Process SED templates\n");
    nWaves = rawSpectra.nWaves;
    waves = (double*)malloc(nWaves*sizeof(double));
    memcpy(waves, rawSpectra.waves, nWaves*sizeof(double));
    // Integrate raw SED templates over time
    printf("# Integrate SED templates over time\n");
    spectra = malloc_2d_double(NMETALS*nAgeList, nWaves);
    for(i = 0; i < NMETALS; report(i++, NMETALS)) 
        for(j = 0; j < nAgeList; ++j) {
            pData = spectra[i*nAgeList + j];
            for(k = 0; k < nWaves; ++k) {
                if (j == 0) {
                    // The first time step of SED templates is typicall not zero
                    // Here assumes that the templates is constant beween zero
                    // and the first time step
                    pData[k] = rawSpectra.data[i*nWaves + k][0]*rawSpectra.age[0];
                    pData[k] += trapz_table(rawSpectra.data[i*nWaves + k],
                                            rawSpectra.age, rawSpectra.nAge, 
                                            rawSpectra.age[0], ageList[j]);

                }
                else
                    pData[k] = trapz_table(rawSpectra.data[i*nWaves + k], 
                                           rawSpectra.age, rawSpectra.nAge, 
                                           ageList[j - 1], ageList[j]);
            }
        }
    free_template(&rawSpectra);
    // Intgrate SED templates over filters
    refSpectra = malloc_2d_double(nFilter*nAgeList, NMETALS);
    // Compute rest frame flux
    // Unit Jy
    printf("# Compute rest frame flux\n");
    for(i = 0; i < NMETALS*nAgeList; ++i) {
        pData = spectra[i];
        for(k = 0; k < nWaves; ++k)
            pData[k] *= JANSKY(waves[k]);
    }
    for(i = 0; i < nRest; ++i) {
        pFilter = filters + i*nWaves;
        for(j = 0; j < nAgeList; ++j) {
            pData = refSpectra[i*nAgeList + j];
            for(k = 0; k < NMETALS; ++k)
                pData[k] = trapz_filter(pFilter, spectra[k*nAgeList + j], waves, nWaves);
        }
    }
    // Compute observer frame flux
    printf("# Compute observer frame flux\n");
    // Transform everything to observer frame
    // Note the flux in this case is a function frequency
    // Therefore the flux has a factor of 1 + z
    for(i = 0; i < nWaves; ++i)
        waves[i] *= 1. + z;
    for(i = 0; i < NMETALS*nAgeList; ++i) {
        pData = spectra[i];
        for(k = 0; k < nWaves; ++k)
            pData[k] *= (1. + z)*absorption[k];
    }
    for(i = nRest; i < nFilter; ++i) {
        pFilter = filters + i*nWaves;
        for(j = 0; j < nAgeList; ++j) {
            pData = refSpectra[i*nAgeList + j];
            for(k = 0; k < NMETALS; ++k)
                pData[k] = trapz_filter(pFilter, spectra[k*nAgeList + j], waves, nWaves);
        }
    }
    // Interploate SED templates along metallicities
    printf("# Interpolate SED templates along metallicities\n");
    fluxTmp = (double*)malloc(NUM_Z*nAgeList*nFilter*sizeof(double));
    pData = fluxTmp;
    for(i = 0; i < NUM_Z; ++i)
        for(j = 0; j < nAgeList; ++j) 
            for(k = 0; k < nFilter; ++k) 
                *pData++ = interp((double)i, refMetals, refSpectra[k*nAgeList + j], NMETALS);

    free_2d_double(spectra, NMETALS*nAgeList);
    free_2d_double(refSpectra, nFilter*nAgeList); 
    timing_end();
    return fluxTmp;   
}


void trace_progenitors(int snap, int galIdx, struct node *branch, int *pNProg) {
    int metals;
    float sfr;
    if (galIdx >= 0) {
        sfr = galSFR[snap][galIdx];
        if (sfr > 0.) {
            *pNProg += 1;
            if (*pNProg >= MAX_NODE) {
                printf("Error: Number of progenitors exceeds MAX_NODE\n");
                exit(0);
            }
            metals = (int)(galMetals[snap][galIdx]*1000 - .5);
            if (metals < MIN_Z)
                metals = MIN_Z;
            else if (metals > MAX_Z)
                metals = MAX_Z;
            branch[*pNProg].snap = snap;
            branch[*pNProg].metals = metals;
            branch[*pNProg].sfr = sfr;
            //printf("snap %d, metals %d, sfr %.3f\n", snap, metals, sfr);
        }
        trace_progenitors(snap - 1, firstProgenitor[snap][galIdx], branch, pNProg);
        trace_progenitors(snap, nextProgenitor[snap][galIdx], branch, pNProg);
    }
}


inline int trace_merger_tree(int snap, int galIdx, struct node *branch) {
    int nProg = -1;
    int metals;
    float sfr = galSFR[snap][galIdx];
    
    if (sfr > 0.) {
        ++nProg;
        metals = (int)(galMetals[snap][galIdx]*1000 - .5);
        if (metals < MIN_Z)
            metals = MIN_Z;
        else if (metals > MAX_Z)
            metals = MAX_Z;
        branch[nProg].snap = snap;
        branch[nProg].metals = metals;
        branch[nProg].sfr = sfr;
    }
    trace_progenitors(snap - 1, firstProgenitor[snap][galIdx], branch, &nProg);
    ++nProg;
    if (nProg == 0) {
        printf("Warning: snapshot %d, index %d\n", snap, galIdx);
        printf("         the star formation rate is zero throughout the histroy\n");
    }
    return nProg;
}


inline void compute_spectrum(double *spectrum, int cSnap,
                             struct node *branch, int nProg, struct template *spectra) {
    int i, j;
    int snap;
    double *pData;
    double sfr;
    for(i = 0; i < spectra->nWaves; ++i)
        *(spectrum + i) = 0.;

    for(i = 0; i < nProg; ++i) {
        snap = branch[i].snap;
        pData = spectra->data[branch[i].metals*spectra->nAge + cSnap - branch[i].snap];
        sfr = branch[i].sfr;
        for(j = 0; j < spectra->nWaves; ++j) 
            *(spectrum + j) += sfr*pData[j];    
        
    }    
}


float *galaxy_spectra_cext(double z, int tSnap, 
                           int *indices, int nGal,
                           double *ageList, int nAgeList,
                           int nWaves) {
    int i, j, k;
    double *fluxTmp = init_templates_sp(ageList, nAgeList);
    double *flux = malloc(nWaves*sizeof(double));
    double *pData;

    float *output = malloc(nGal*nWaves*sizeof(float));
    float *pOutput = output;

    int nProg;
    struct node branch[MAX_NODE];
    double sfr;

    timing_start("# Compute SEDs\n");
    for(i = 0; i < nGal; report(i++, nGal)) {
        nProg = trace_merger_tree(tSnap, indices[i], branch);
        // Initialise fluxes
        for(j = 0; j < nWaves; ++j)
            flux[j] = TOL;
        // Sum contributions from all progenitors
        for(j = 0; j < nProg; ++j) {
            sfr = branch[j].sfr;
            pData = fluxTmp + (branch[j].metals*nAgeList + tSnap - branch[j].snap)*nWaves;
            for(k = 0; k < nWaves; ++k) 
                flux[k] += sfr*pData[k];    
        }       
        // Store output
        for(j = 0; j < nWaves; ++j)
            *pOutput++ = (float)flux[j];
    }
    free(flux);
    free(fluxTmp);
    timing_end();
    return output;
}


float *galaxy_mags_cext(double z, int tSnap,
                        int *indices, int nGal,
                        double *ageList, int nAgeList,
                        double *filters, int nRest, int nObs,
                        double *absorption) {
    int i, j, k;
    int nFilter = nObs + nRest;
    double *fluxTmp = init_templates_ph(z, ageList, nAgeList, filters, 
                                        nRest, nObs, absorption);
    double *flux = malloc(nFilter*sizeof(double));
    double *pData;

    float *output = malloc(nGal*nFilter*sizeof(float));
    float *pOutput = output;

    int nProg;
    struct node branch[MAX_NODE];
    double sfr;
    
    timing_start("# Compute magnitudes\n");
    for(i = 0; i < nGal; report(i++, nGal)) {
        nProg = trace_merger_tree(tSnap, indices[i], branch);
        // Initialise fluxes
        for(j = 0; j < nFilter; ++j)
            flux[j] = TOL;
        // Sum contributions from all progentiors
        for(j = 0; j < nProg; ++j) {
            sfr = branch[j].sfr;    
            pData = fluxTmp + (branch[j].metals*nAgeList + tSnap - branch[j].snap)*nFilter;
            for(k = 0 ; k < nFilter; ++k) 
                flux[k] += sfr*pData[k];
        }
        // Convert fluxes to magnitudes
        for(j = 0; j < nFilter; ++j)
            *pOutput++ = (float)M_AB(flux[j]);
    }
    free(flux);
    free(fluxTmp);
    timing_end();
    return output;
}



