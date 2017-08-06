import os
from warnings import warn
from time import time
from struct import unpack

from libc.stdlib cimport malloc, free
from libc.math cimport exp, log

import numpy as np
from numpy import isnan, isscalar, vectorize
from pandas import DataFrame
from scipy.interpolate import interp1d
from astropy.cosmology import FlatLambdaCDM
from dragons import meraxes

# Global variables
#========================================================================================
global sTime, inputDict
inputDict = "/lustre/projects/p113_astro/yqiu/magcalc/input/"
filterList = {"B435":os.path.join(inputDict, "HST_ACS_F435W.npy"), 
              "V606":os.path.join(inputDict, "HST_ACS_F606W.npy"), 
              "i775":os.path.join(inputDict, "HST_ACS_F775W.npy"), 
              "I814":os.path.join(inputDict, "HST_ACS_F814W.npy"), 
              "z850":os.path.join(inputDict, "HST_ACS_F850LP.npy"), 
              "Y098":os.path.join(inputDict, "HST_IR_F098M.npy"), 
              "Y105":os.path.join(inputDict, "HST_IR_F105W.npy"), 
              "J125":os.path.join(inputDict, "HST_IR_F125W.npy"), 
              "H160":os.path.join(inputDict, "HST_IR_F160W.npy"), 
              "3.6":os.path.join(inputDict,  "HST_IRAC_3.6.npy")}

 
cdef extern from "mag_calc_cext.h":
    int **firstProgenitor
    int **nextProgenitor
    float **galMetals
    float **galSFR
#========================================================================================


cdef int *init_1d_int(int[:] memview):
    cdef:
        int nSize = memview.shape[0]
        int *p = <int*>malloc(nSize*sizeof(int))
        int[:] cMemview = <int[:nSize]>p
    cMemview[...] = memview
    return p


cdef float *init_1d_float(float[:] memview):
    cdef:
        int nSize = memview.shape[0]
        float *p = <float*>malloc(nSize*sizeof(float))
        float[:] cMemview = <float[:nSize]>p
    cMemview[...] = memview
    return p


cdef double *init_1d_double(double[:] memview):
    cdef:
        int nSize = memview.shape[0]
        double *p = <double*>malloc(nSize*sizeof(double))
        double[:] cMemview = <double[:nSize]>p
    cMemview[...] = memview
    return p


def timing_start(text):
    global sTime
    sTime = time()
    print "#**********************************************************"
    print text
 

def timing_end():
    global sTime
    elapsedTime = int(time() - sTime)
    print "# Done!"
    print "# Elapsed time: %i min %i sec"%(elapsedTime/60, elapsedTime%60)
    print "#**********************************************************\n"


def get_wavelength():
    global inputDict
    fp = open(os.path.join(inputDict, "sed_waves.bin"), "rb")
    nWaves = unpack('i', fp.read(sizeof(int)))[0]
    waves = np.array(unpack('%dd'%nWaves, fp.read(nWaves*sizeof(double))))
    fp.close()
    return waves


def HST_filters(filterNames):
    global filterList
    obsBands = []
    for name in filterNames:
        obsBands.append([name, np.load(filterList[name])])
    return obsBands


def read_filters(restFrame, obsBands, z):
    waves = get_wavelength()
    nRest = len(restFrame)
    nObs = len(obsBands)
    filters = np.zeros([nRest + nObs, len(waves)])
    obsWaves = (1 + z)*waves
    for i in xrange(nRest):
        centre, bandWidth = restFrame[i]
        lower = centre - bandWidth/2.
        upper = centre + bandWidth/2.
        filters[i] = np.interp(waves, [lower, upper], [1., 1.], left = 0., right = 0.)
        filters[i] /= waves*np.log(upper/lower)
    for i in xrange(nObs):
        fWaves, trans = obsBands[i][1]
        filters[nRest + i] = np.interp(obsWaves, fWaves, trans, left = 0., right = 0.)
        filters[nRest + i] /= obsWaves*np.trapz(trans/fWaves, fWaves)
    return filters.flatten()


def read_meraxes(fname, int snapMax, h):
    timing_start("# Read meraxes output")
    cdef:
        int snapNum = snapMax+ 1
        int snapMin = snapMax
        int snap, N
        int[:] intMemview1, intMemview2
        float[:] floatMemview1, floatMemview2
    global firstProgenitor 
    global nextProgenitor
    global galMetals
    global galSFR
    firstProgenitor = <int**>malloc(snapNum*sizeof(int*))
    nextProgenitor = <int**>malloc(snapMax*sizeof(int*))
    galMetals = <float**>malloc(snapNum*sizeof(float*))
    galSFR = <float**>malloc(snapNum*sizeof(float*))

    meraxes.set_little_h(h = h)
    for snap in xrange(snapMax, -1, -1):
        try:
            # Copy metallicity and star formation rate to the pointers
            gals = meraxes.io.read_gals(fname, snap, 
                                        ["StellarMass", "MetalsStellarMass", "Sfr"])
            metals = gals["MetalsStellarMass"]/gals["StellarMass"]
            metals[isnan(metals)] = 0.001
            galMetals[snap] = init_1d_float(metals)
            galSFR[snap] = init_1d_float(gals["Sfr"])
            snapMin = snap
            gals = None
        except IndexError:
            print "# There is no galaxies in snapshot %d"%snap
            break;
    print "# snapMin = %d"%snapMin
    for snap in xrange(snapMin, snapNum):
        # Copy first progenitor indices to the pointer
        firstProgenitor[snap] = \
        init_1d_int(meraxes.io.read_firstprogenitor_indices(fname, snap))
        # Copy next progenitor indices to the pointer
        if snap < snapMax:
            nextProgenitor[snap] = \
            init_1d_int(meraxes.io.read_nextprogenitor_indices(fname, snap))

    timing_end()    
    return snapMin


cdef void free_meraxes(int snapMin, int snapMax):
    cdef int i
    # There is no indices in nextProgenitor[snapMax]
    for i in xrange(snapMin, snapMax):
        free(nextProgenitor[i])

    snapMax += 1
    for i in xrange(snapMin, snapMax):
        free(firstProgenitor[i])
        free(galMetals[i])
        free(galSFR[i])

    free(firstProgenitor)
    free(nextProgenitor)
    free(galMetals)
    free(galSFR)

def Lyman_absorption_Fan(double[:] obsWaves, double z):
    cdef:
        int i
        int nWaves = obsWaves.shape[0]
        double[:] absorption = np.zeros(nWaves)
        double tau
        double ratio
    for i in xrange(nWaves):
        ratio = obsWaves[i]/1216.
        if ratio < 1. + z:
            if ratio < 6.5:
                tau = .85*(ratio/5.)**4.3
            else:
                tau = .15*(ratio/5.)**10.9
        else:
            tau = 0.
        absorption[i] = exp(-tau)
    
    return np.asarray(absorption)


DEF NLYMAN = 39 # Inoue calculated the absorption of 40th Lyman series

def Lyman_absorption_Inoue(double[:] obsWaves, double z):
    # Reference Inoue et al. 2014
    cdef:
        double LymanSeries[NLYMAN]
        double LAF1[NLYMAN]
        double LAF2[NLYMAN]
        double LAF3[NLYMAN]
        double DLA1[NLYMAN]
        double DLA2[NLYMAN]

    LymanSeries[:] = [1215.67, 1025.72, 972.537, 949.743, 937.803,
                      930.748, 926.226, 923.150, 920.963, 919.352,
                      918.129, 917.181, 916.429, 915.824, 915.329,
                      914.919, 914.576, 914.286, 914.039, 913.826,
                      913.641, 913.480, 913.339, 913.215, 913.104,
                      913.006, 912.918, 912.839, 912.768, 912.703,
                      912.645, 912.592, 912.543, 912.499, 912.458,
                      912.420, 912.385, 912.353, 912.324]
    LAF1[:] = [1.690e-02, 4.692e-03, 2.239e-03, 1.319e-03, 8.707e-04,
               6.178e-04, 4.609e-04, 3.569e-04, 2.843e-04, 2.318e-04,
               1.923e-04, 1.622e-04, 1.385e-04, 1.196e-04, 1.043e-04,
               9.174e-05, 8.128e-05, 7.251e-05, 6.505e-05, 5.868e-05,
               5.319e-05, 4.843e-05, 4.427e-05, 4.063e-05, 3.738e-05,
               3.454e-05, 3.199e-05, 2.971e-05, 2.766e-05, 2.582e-05,
               2.415e-05, 2.263e-05, 2.126e-05, 2.000e-05, 1.885e-05,
               1.779e-05, 1.682e-05, 1.593e-05, 1.510e-05]
    LAF2[:] = [2.354e-03, 6.536e-04, 3.119e-04, 1.837e-04, 1.213e-04,
               8.606e-05, 6.421e-05, 4.971e-05, 3.960e-05, 3.229e-05,
               2.679e-05, 2.259e-05, 1.929e-05, 1.666e-05, 1.453e-05,
               1.278e-05, 1.132e-05, 1.010e-05, 9.062e-06, 8.174e-06,
               7.409e-06, 6.746e-06, 6.167e-06, 5.660e-06, 5.207e-06,
               4.811e-06, 4.456e-06, 4.139e-06, 3.853e-06, 3.596e-06,
               3.364e-06, 3.153e-06, 2.961e-06, 2.785e-06, 2.625e-06,
               2.479e-06, 2.343e-06, 2.219e-06, 2.103e-06]
    LAF3[:] = [1.026e-04, 2.849e-05, 1.360e-05, 8.010e-06, 5.287e-06,
               3.752e-06, 2.799e-06, 2.167e-06, 1.726e-06, 1.407e-06,
               1.168e-06, 9.847e-07, 8.410e-07, 7.263e-07, 6.334e-07,
               5.571e-07, 4.936e-07, 4.403e-07, 3.950e-07, 3.563e-07,
               3.230e-07, 2.941e-07, 2.689e-07, 2.467e-07, 2.270e-07,
               2.097e-07, 1.943e-07, 1.804e-07, 1.680e-07, 1.568e-07,
               1.466e-07, 1.375e-07, 1.291e-07, 1.214e-07, 1.145e-07,
               1.080e-07, 1.022e-07, 9.673e-08, 9.169e-08]
    DLA1[:] = [1.617e-04, 1.545e-04, 1.498e-04, 1.460e-04, 1.429e-04,
               1.402e-04, 1.377e-04, 1.355e-04, 1.335e-04, 1.316e-04,
               1.298e-04, 1.281e-04, 1.265e-04, 1.250e-04, 1.236e-04,
               1.222e-04, 1.209e-04, 1.197e-04, 1.185e-04, 1.173e-04,
               1.162e-04, 1.151e-04, 1.140e-04, 1.130e-04, 1.120e-04,
               1.110e-04, 1.101e-04, 1.091e-04, 1.082e-04, 1.073e-04,
               1.065e-04, 1.056e-04, 1.048e-04, 1.040e-04, 1.032e-04,
               1.024e-04, 1.017e-04, 1.009e-04, 1.002e-04]
    DLA2[:] = [5.390e-05, 5.151e-05, 4.992e-05, 4.868e-05, 4.763e-05, 
               4.672e-05, 4.590e-05, 4.516e-05, 4.448e-05, 4.385e-05, 
               4.326e-05, 4.271e-05, 4.218e-05, 4.168e-05, 4.120e-05,
               4.075e-05, 4.031e-05, 3.989e-05, 3.949e-05, 3.910e-05, 
               3.872e-05, 3.836e-05, 3.800e-05, 3.766e-05, 3.732e-05,
               3.700e-05, 3.668e-05, 3.637e-05, 3.607e-05, 3.578e-05,
               3.549e-05, 3.521e-05, 3.493e-05, 3.466e-05, 3.440e-05,
               3.414e-05, 3.389e-05, 3.364e-05, 3.339e-05]

    cdef:
        int i, j
        int nWaves = obsWaves.shape[0]
        double[:] absorption = np.zeros(nWaves)
        double tau
        double lamObs, ratio

    for i in xrange(nWaves):
        tau = 0.
        lamObs = obsWaves[i]
        # Lyman series
        for j in xrange(NLYMAN):
            ratio = lamObs/LymanSeries[j]
            if ratio < 1. + z:
                # LAF terms
                if ratio < 2.2:
                    tau += LAF1[j]*ratio**1.2
                elif ratio < 5.7:
                    tau += LAF2[j]*ratio**3.7
                else:
                    tau += LAF3[j]*ratio**5.5
                # DLA terms
                if ratio < 3.:
                    tau += DLA1[j]*ratio**2.
                else:
                    tau += DLA2[j]*ratio**3.
        # Lyman continuum
        ratio = lamObs/912.
        # LAF terms
        if z < 1.2:
            if ratio < 1. + z:
                tau += .325*(ratio**1.2 - (1. + z)**-.9*ratio**2.1)
        elif z < 4.7:
            if ratio < 2.2:
                tau += 2.55e-2*(1. + z)**1.6*ratio**2.1 + .325*ratio**1.2 - .25*ratio**2.1
            elif ratio < 1. + z:
                tau += 2.55e-2*((1. + z)**1.6*ratio**2.1 - ratio**3.7)
        else:
            if ratio < 2.2:
                tau += 5.22e-4*(1. + z)**3.4*ratio**2.1 + .325*ratio**1.2 - 3.14e-2*ratio**2.1
            elif ratio < 5.7:
                tau += 5.22e-4*(1. + z)**3.4*ratio**2.1 + .218*ratio**2.1 - 2.55e-2*ratio**3.7
            elif ratio < 1. + z:
                tau += 5.22e-4*((1. + z)**3.4*ratio**2.1 - ratio**5.5)
        # DLA terms
        if z < 2.:
            if ratio < 1. + z:
                tau += .211*(1. + z)**2. - 7.66e-2*(1. + z)**2.3*ratio**-.3 - .135*ratio**2.
        else:
            if ratio < 3.:
                tau += .634 + 4.7e-2*(1. + z)**3. - 1.78e-2*(1. + z)**3.3*ratio**-.3
            elif ratio < 1. + z:
                tau += 4.7e-2*(1. + z)**3. - 1.78e-2*(1. + z)**3.3*ratio**-.3 - \
                       2.92e-2*ratio**3.
        absorption[i] = exp(-tau)

    return np.asarray(absorption)


def get_output_name(prefix, snap, path):
    fname = prefix + "%03d.hdf5"%snap
    # Avoid repeated name
    idx = 2
    fileList = os.listdir(path)
    while fname in fileList:
        fname = prefix + "%03d_%d.hdf5"%(snap, idx)
        idx += 1
    return os.path.join(path, fname)


def get_age_list(fname, snap, nAgeList, h):
    travelTime = meraxes.io.read_snaplist(fname, h)[2]*1e6 # Convert Myr to yr
    ageList = np.zeros(nAgeList)
    for i in xrange(nAgeList):
        ageList[i] = travelTime[snap - i - 1] - travelTime[snap]
    return ageList


cdef extern from "mag_calc_cext.h":
    float *galaxy_spectra_cext(double z, int tSnap, 
                               int *indices, int nGal,
                               double *ageList, int nAgeList,
                               int nWaves)


    float *galaxy_mags_cext(double z, int tSnap,
                            int *indices, int nGal,
                            double *ageList, int nAgeList,
                            double *filters, int nRest, int nObs,
                            double *absorption)

"""
def galaxy_spectra(fname, snapList, idxList, h, path = "./"):
    cdef:
        int i
        int snap, nSnap
        int sanpMin, snapMax

    if isscalar(snapList):
        snapMax = snapList
        nSnap = 1
        snapList = [snapList]
        idxList = [idxList]
    else:
        snapMax = max(snapList)
        nSnap = len(snapList)

    snapMin = read_meraxes(fname, snapMax, h)

    waves = get_wavelength()
    cdef:
        int nWaves = len(waves)
        int nGal
        int *indices

        int nAgeList
        double *ageList

        double z
        
        float *cOutput 
        float[:] mvOutput
        float[:] mvSpectra

    for i in xrange(nSnap):
        snap = snapList[i]
        galIndices = idxList[i]
        nGal = len(galIndices)
        indices = init_1d_int(np.asarray(galIndices, dtype = 'i4'))
        nAgeList = snap - snapMin + 1
        ageList= init_1d_double(get_age_list(fname, snap, nAgeList, h))
        z = meraxes.io.grab_redshift(fname, snap)

        cOutput = galaxy_spectra_cext(z, snap, indices, nGal, ageList, nAgeList, nWaves)
        mvOutput = <float[:nGal*nWaves]>cOutput

        DataFrame(np.asarray(mvOutput, dtype = 'f4').reshape(nGal, -1), 
                  index = galIndices, columns = waves). \
        to_hdf(get_output_name("spectra", snap, path), "w")

        if len(snapList) == 1:
            mvSpectra = np.zeros(nGal*nWaves, dtype = 'f4')
            mvSpectra[...] = mvOutput
            spectra = np.asarray(mvSpectra, dtype = 'f4').reshape(nGal, -1)

        free(indices)       
        free(ageList)
        free(cOutput)

    free_meraxes(snapMin, snapMax)

    if len(snapList) == 1:
        return spectra, waves
"""


def galaxy_mags(fname, snapList, idxList, h, Om0, 
                restFrame = [[1600., 100.]], obsBands = [], 
                path = "./"):
    cosmo = FlatLambdaCDM(H0 = 100.*h, Om0 = Om0)
   
    cdef:
        int i
        int snap, nSnap
        int sanpMin, snapMax

    if isscalar(snapList):
        snapMax = snapList
        nSnap = 1
        snapList = [snapList]
        idxList = [idxList]
    else:
        snapMax = max(snapList)
        nSnap = len(snapList)

    snapMin = read_meraxes(fname, snapMax, h)

    waves = get_wavelength()
    cdef:
        int nWaves = len(waves)
        int nGal
        int *indices

        int nAgeList
        double *ageList

        int nRest = len(restFrame)
        int nObs = len(obsBands)
        double z
        double *filters 
        double *absorption
        
        float *cOutput 
        float[:] mvOutput
        float[:] mvMags

    names = []
    for i in xrange(nRest):
        names.append("M%d"%restFrame[i][0])
    for i in xrange(nObs):
        names.append(obsBands[i][0])

    for i in xrange(nSnap):
        snap = snapList[i]
        galIndices = idxList[i]
        nGal = len(galIndices)
        indices = init_1d_int(np.asarray(galIndices, dtype = 'i4'))
        nAgeList = snap - snapMin + 1
        ageList= init_1d_double(get_age_list(fname, snap, nAgeList, h))
        z = meraxes.io.grab_redshift(fname, snap)
        filters = init_1d_double(read_filters(restFrame, obsBands, z))
        absorption = init_1d_double(Lyman_absorption_Inoue((1. + z)*waves, z))

        cOutput = galaxy_mags_cext(z, snap,
                                   indices, nGal,
                                   ageList, nAgeList,
                                   filters, nRest, nObs,
                                   absorption)
        mvOutput = <float[:nGal*(nRest + nObs)]>cOutput
        output = np.asarray(mvOutput, dtype = 'f4').reshape(nGal, -1)
        # Add distance modulus to apparent magnitudes
        output[:, nRest:] += cosmo.distmod(z).value

        DataFrame(output, index = galIndices, columns = names).\
        to_hdf(get_output_name("mags", snap, path), "w")

        if len(snapList) == 1:
            mvMags = np.zeros(nGal*(nRest + nObs), dtype = 'f4')
            mvMags[...] = mvOutput
            mags = np.asarray(mvMags, dtype = 'f4').reshape(nGal, -1)

        free(indices)       
        free(ageList)
        free(filters)
        free(absorption)
        free(cOutput)

    free_meraxes(snapMin, snapMax)

    if len(snapList) == 1:
        return mags


def dust_extinction(M1600, z):
    # Reference Mason et al. 2015, equation 4
    #           Bouwens 2014 et al. 2014, Table 3
    if isscalar(M1600):
        M1600 = np.array([M1600])
    else:
        M1600 = np.asarray(M1600)
    c = -2.33
    M0 = -19.5
    sigma = .34
    intercept = interp1d([2.5, 3.8, 5., 5.9, 7., 8.], 
                         [-1.7, -1.85, -1.91, -2., -2.05, -2.13], 
                         fill_value = 'extrapolate')      
    slope = interp1d([2.5, 3.8, 5.0, 5.9, 7.0, 8.0], 
                     [-.2, -.11, -.14, -.2, -.2, -.15], 
                     fill_value = 'extrapolate')
    beta = np.zeros(len(M1600))
    beta[M1600 >= M0] = \
    (intercept(z) - c)*np.exp(slope(z)*(M1600[M1600 >= M0] - M0)/(intercept(z) - c)) + c
    beta[M1600 < M0] = slope(z)*(M1600[M1600 < M0] - M0) + intercept(z)
    A1600 = 4.43 + .79*log(10)*sigma**2 + 1.99*beta
    if A1600.min() < 0.:
        warn("Redshift %.3f is beyond the range of the dust model"%z)
        A1600[:] = 0.
    return A1600


@vectorize
def reddening_curve(lam):
    # Reference Calzetti et al. 2000, Liu et al. 2016
    lam *= 1e-4 # Convert angstrom to mircometer
    if lam < .12 or lam > 2.2:
        warn("Warning: wavelength is beyond the range of the reddening curve")
    if lam < .091:
        return 0.
    elif lam < .12:
        return -92.44949*lam + 23.21331
    elif lam < .63:
        return 2.659*(-2.156 + 1.509/lam - 0.198/lam**2 + 0.011/lam**3) + 4.05
    elif lam < 2.2:
        return  2.659*(-1.857 + 1.040/lam) + 4.05
    else:
        return max(0., -.57136*lam + 1.62620)


def reddening(waves, M1600, z):
    # waves must be in a unit of angstrom
    # The reddening curve is normalised by the value at 1600 A
    A1600 = dust_extinction(M1600, z)
    if isscalar(waves):
        return reddening_curve(waves)/reddening_curve(1600.)*A1600
    else:
        waves = np.asarray(waves)
        return reddening_curve(waves)/reddening_curve(1600.)*A1600.reshape(-1, 1)


